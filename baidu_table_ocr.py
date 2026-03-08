#!/usr/bin/env python3
"""Call Baidu OCR Table Recognition V2.

Features:
- Supports API Key + Secret Key auto token exchange.
- Supports local image/PDF/OFD and remote image URL.
- By default saves timestamped JSON/XLSX to ~/Desktop/表格识别.
- If no input is provided, listens for Control+P, opens an adjustable screenshot overlay,
  then sends the captured region to Baidu OCR and exports Excel.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from PIL import ImageGrab, ImageTk

TOKEN_URL = "https://aip.baidubce.com/oauth/2.0/token"
TABLE_URL = "https://aip.baidubce.com/rest/2.0/ocr/v1/table"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp"}
DEFAULT_OUTPUT_DIR = Path.home() / "Desktop" / "表格识别"
DEFAULT_HOTKEY = "<ctrl>+p"
LEGACY_DEFAULT_JSON_NAME = "baidu_table_ocr_result.json"
LEGACY_DEFAULT_EXCEL_NAME = "baidu_table_ocr_result.xlsx"
PURPLE = "#A855F7"


class ScreenshotSelector:
    HANDLE_SIZE = 10
    MIN_SIZE = 20

    def __init__(self) -> None:
        import tkinter as tk

        self.tk = tk
        self.background_image = ImageGrab.grab()
        self.root = tk.Tk()
        self.root.title("表格识别截图")
        self.root.attributes("-fullscreen", True)
        self.root.attributes("-topmost", True)
        self.root.overrideredirect(True)
        self.root.configure(bg="black")
        self.canvas = tk.Canvas(self.root, bg="black", highlightthickness=0, cursor="crosshair")
        self.canvas.pack(fill="both", expand=True)
        self.root.update_idletasks()
        self.screen_w = int(self.root.winfo_screenwidth())
        self.screen_h = int(self.root.winfo_screenheight())
        self.pixel_w, self.pixel_h = self.background_image.size
        self.scale_x = self.pixel_w / self.screen_w if self.screen_w else 1.0
        self.scale_y = self.pixel_h / self.screen_h if self.screen_h else 1.0
        display_image = self.background_image
        if (self.pixel_w, self.pixel_h) != (self.screen_w, self.screen_h):
            display_image = self.background_image.resize((self.screen_w, self.screen_h))
        self.background_photo = ImageTk.PhotoImage(display_image)
        self.canvas.create_image(0, 0, image=self.background_photo, anchor="nw", tags="background")

        self.selection: tuple[int, int, int, int] | None = None
        self.anchor: tuple[int, int] | None = None
        self.mode: str | None = None
        self.active_handle: str | None = None
        self.move_offset: tuple[int, int] = (0, 0)
        self.cancelled = False
        self.confirmed = False

        self._bind_events()

    def _bind_events(self) -> None:
        self.canvas.bind("<ButtonPress-1>", self.on_mouse_down)
        self.canvas.bind("<B1-Motion>", self.on_mouse_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_mouse_up)
        self.canvas.bind("<Motion>", self.on_mouse_move)
        self.root.bind("<Return>", self.on_confirm)
        self.root.bind("<Escape>", self.on_cancel)
        self.root.focus_force()

    @staticmethod
    def _normalize_rect(rect: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
        x1, y1, x2, y2 = rect
        return min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)

    def _clamp_point(self, x: int, y: int) -> tuple[int, int]:
        return max(0, min(self.screen_w, x)), max(0, min(self.screen_h, y))

    def _selection_valid(self) -> bool:
        if not self.selection:
            return False
        x1, y1, x2, y2 = self.selection
        return (x2 - x1) >= self.MIN_SIZE and (y2 - y1) >= self.MIN_SIZE

    def _point_in_rect(self, x: int, y: int, rect: tuple[int, int, int, int]) -> bool:
        x1, y1, x2, y2 = rect
        return x1 <= x <= x2 and y1 <= y <= y2

    def _handle_rects(self) -> dict[str, tuple[int, int, int, int]]:
        if not self.selection:
            return {}
        x1, y1, x2, y2 = self.selection
        hs = self.HANDLE_SIZE
        cx = (x1 + x2) // 2
        cy = (y1 + y2) // 2
        points = {
            "nw": (x1, y1),
            "n": (cx, y1),
            "ne": (x2, y1),
            "e": (x2, cy),
            "se": (x2, y2),
            "s": (cx, y2),
            "sw": (x1, y2),
            "w": (x1, cy),
        }
        return {k: (px - hs, py - hs, px + hs, py + hs) for k, (px, py) in points.items()}

    def _hit_handle(self, x: int, y: int) -> str | None:
        for name, (x1, y1, x2, y2) in self._handle_rects().items():
            if x1 <= x <= x2 and y1 <= y <= y2:
                return name
        return None

    def _redraw_selection(self) -> None:
        self.canvas.delete("selection")
        if not self.selection:
            return
        x1, y1, x2, y2 = self.selection
        self.canvas.create_rectangle(x1, y1, x2, y2, outline=PURPLE, width=3, tags="selection")
        for hx1, hy1, hx2, hy2 in self._handle_rects().values():
            self.canvas.create_rectangle(hx1, hy1, hx2, hy2, fill=PURPLE, outline=PURPLE, tags="selection")

    def on_mouse_down(self, event) -> None:
        x, y = self._clamp_point(int(event.x), int(event.y))
        handle = self._hit_handle(x, y)
        if handle:
            self.mode = "resize"
            self.active_handle = handle
            return
        if self.selection and self._point_in_rect(x, y, self.selection):
            self.mode = "move"
            self.move_offset = (x - self.selection[0], y - self.selection[1])
            return
        self.mode = "draw"
        self.anchor = (x, y)
        self.selection = (x, y, x, y)
        self._redraw_selection()

    def on_mouse_drag(self, event) -> None:
        x, y = self._clamp_point(int(event.x), int(event.y))
        if self.mode == "draw" and self.anchor:
            self.selection = self._normalize_rect((self.anchor[0], self.anchor[1], x, y))
            self._redraw_selection()
            return
        if self.mode == "move" and self.selection:
            x1, y1, x2, y2 = self.selection
            width = x2 - x1
            height = y2 - y1
            nx1 = x - self.move_offset[0]
            ny1 = y - self.move_offset[1]
            nx1 = max(0, min(self.screen_w - width, nx1))
            ny1 = max(0, min(self.screen_h - height, ny1))
            self.selection = (nx1, ny1, nx1 + width, ny1 + height)
            self._redraw_selection()
            return
        if self.mode == "resize" and self.selection and self.active_handle:
            x1, y1, x2, y2 = self.selection
            if "w" in self.active_handle:
                x1 = x
            if "e" in self.active_handle:
                x2 = x
            if "n" in self.active_handle:
                y1 = y
            if "s" in self.active_handle:
                y2 = y
            x1, y1, x2, y2 = self._normalize_rect((x1, y1, x2, y2))
            if (x2 - x1) < self.MIN_SIZE:
                if "w" in self.active_handle:
                    x1 = x2 - self.MIN_SIZE
                else:
                    x2 = x1 + self.MIN_SIZE
            if (y2 - y1) < self.MIN_SIZE:
                if "n" in self.active_handle:
                    y1 = y2 - self.MIN_SIZE
                else:
                    y2 = y1 + self.MIN_SIZE
            x1, y1 = self._clamp_point(x1, y1)
            x2, y2 = self._clamp_point(x2, y2)
            self.selection = self._normalize_rect((x1, y1, x2, y2))
            self._redraw_selection()

    def on_mouse_up(self, _event) -> None:
        self.mode = None
        self.active_handle = None
        if self.selection:
            self.selection = self._normalize_rect(self.selection)
            self._redraw_selection()

    def on_mouse_move(self, event) -> None:
        x, y = self._clamp_point(int(event.x), int(event.y))
        handle = self._hit_handle(x, y)
        if handle:
            self.canvas.configure(cursor="sizing")
        elif self.selection and self._point_in_rect(x, y, self.selection):
            self.canvas.configure(cursor="fleur")
        else:
            self.canvas.configure(cursor="crosshair")

    def on_confirm(self, _event) -> None:
        if not self._selection_valid():
            return
        self.confirmed = True
        self.root.quit()

    def on_cancel(self, _event) -> None:
        self.cancelled = True
        self.root.quit()

    def run(self) -> tuple[int, int, int, int] | None:
        try:
            self.root.mainloop()
        finally:
            try:
                self.root.destroy()
            except Exception:
                pass
        if self.cancelled or not self.confirmed or not self.selection:
            return None
        x1, y1, x2, y2 = self._normalize_rect(self.selection)
        return (
            int(round(x1 * self.scale_x)),
            int(round(y1 * self.scale_y)),
            int(round(x2 * self.scale_x)),
            int(round(y2 * self.scale_y)),
        )


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        values[key] = value
    return values


def str_to_bool(value: str | bool | None, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def http_post_json(url: str, *, headers: dict[str, str] | None = None, data: bytes = b"") -> dict[str, Any]:
    req = Request(url, data=data, headers=headers or {}, method="POST")
    with urlopen(req, timeout=120) as resp:
        content = resp.read().decode("utf-8")
    return json.loads(content)


def get_access_token(api_key: str, secret_key: str) -> str:
    query = urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": api_key,
            "client_secret": secret_key,
        }
    )
    url = f"{TOKEN_URL}?{query}"
    data = http_post_json(
        url,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        data=b"",
    )
    token = data.get("access_token")
    if not token:
        raise RuntimeError(f"Failed to get access_token: {json.dumps(data, ensure_ascii=False)}")
    return str(token)


def read_file_base64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def build_payload(input_file: Path | None, input_url: str | None, page_num: int | None, return_excel: bool, cell_contents: bool) -> dict[str, str]:
    payload: dict[str, str] = {
        "return_excel": "true" if return_excel else "false",
        "cell_contents": "true" if cell_contents else "false",
    }

    if input_url:
        payload["url"] = input_url
        return payload

    if not input_file:
        raise ValueError("Please provide BAIDU_OCR_INPUT_FILE or BAIDU_OCR_INPUT_URL.")
    if not input_file.exists() or not input_file.is_file():
        raise FileNotFoundError(f"Input file not found: {input_file}")

    suffix = input_file.suffix.lower()
    b64 = read_file_base64(input_file)
    if suffix in IMAGE_SUFFIXES:
        payload["image"] = b64
    elif suffix == ".pdf":
        payload["pdf_file"] = b64
        if page_num is not None:
            payload["pdf_file_num"] = str(page_num)
    elif suffix == ".ofd":
        payload["ofd_file"] = b64
        if page_num is not None:
            payload["ofd_file_num"] = str(page_num)
    else:
        raise ValueError(
            f"Unsupported input suffix: {suffix}. Supported image types: {sorted(IMAGE_SUFFIXES)}, plus .pdf and .ofd"
        )
    return payload


def save_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def save_excel_if_present(path: Path, data: dict[str, Any]) -> bool:
    excel_b64 = data.get("excel_file")
    if not excel_b64:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(base64.b64decode(excel_b64))
    return True


def merge_config(env_file: Path) -> dict[str, str]:
    config = load_env_file(env_file)
    for key, value in os.environ.items():
        if key.startswith("BAIDU_OCR_"):
            config[key] = value
    return config


def default_output_dir() -> Path:
    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    return DEFAULT_OUTPUT_DIR


def resolve_output_paths(args: argparse.Namespace, config: dict[str, str], timestamp: str) -> tuple[Path, Path, Path]:
    output_dir_raw = (args.output_dir or config.get("BAIDU_OCR_OUTPUT_DIR", "")).strip()
    output_dir = Path(output_dir_raw).expanduser() if output_dir_raw else default_output_dir()
    output_dir.mkdir(parents=True, exist_ok=True)

    raw_json = args.output_json if args.output_json is not None else config.get("BAIDU_OCR_OUTPUT_JSON", "").strip()
    raw_excel = args.output_excel if args.output_excel is not None else config.get("BAIDU_OCR_OUTPUT_EXCEL", "").strip()

    output_json = Path(raw_json).expanduser() if raw_json and raw_json != LEGACY_DEFAULT_JSON_NAME else output_dir / f"{timestamp}.json"
    output_excel = Path(raw_excel).expanduser() if raw_excel and raw_excel != LEGACY_DEFAULT_EXCEL_NAME else output_dir / f"{timestamp}.xlsx"
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_excel.parent.mkdir(parents=True, exist_ok=True)
    return output_dir, output_json, output_excel


def capture_screenshot_via_hotkey(hotkey: str) -> Path:
    try:
        from pynput import keyboard
    except Exception as exc:
        raise RuntimeError("pynput is unavailable. Please install it and grant Accessibility permission on macOS.") from exc

    trigger = threading.Event()

    def on_activate() -> None:
        trigger.set()

    try:
        listener = keyboard.GlobalHotKeys({hotkey: on_activate})
        listener.start()
    except Exception as exc:
        raise RuntimeError(
            "Failed to start global hotkey listener. On macOS, please grant this Python/terminal app Accessibility permission."
        ) from exc

    print(f"Listening for hotkey {hotkey} ...")
    print("按下后将打开截图框；绘制完成后可拖动紫色边框/角点调整，按 Enter 确认。")

    try:
        while not trigger.is_set():
            time.sleep(0.1)
    finally:
        listener.stop()
        try:
            listener.join(1)
        except Exception:
            pass

    try:
        selector = ScreenshotSelector()
    except Exception as exc:
        raise RuntimeError(
            "Failed to capture screen background. On macOS, please grant Screen Recording permission to your terminal/Python app."
        ) from exc

    bbox = selector.run()
    if not bbox:
        raise RuntimeError("Screenshot capture cancelled by user.")

    try:
        image = selector.background_image.crop(bbox)
    except Exception as exc:
        raise RuntimeError("Failed to crop the selected screen region.") from exc

    temp_path = Path(tempfile.gettempdir()) / f"baidu_table_capture_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
    image.save(temp_path)
    print(f"Screenshot captured: {temp_path}")
    return temp_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Call Baidu OCR Table Recognition V2")
    parser.add_argument("--env-file", default=".env", help="Path to env file (default: .env)")
    parser.add_argument("--input-file", help="Image/PDF/OFD local file path")
    parser.add_argument("--input-url", help="Remote image URL")
    parser.add_argument("--page-num", type=int, help="PDF/OFD page number")
    parser.add_argument("--output-dir", help="Output directory (default: ~/Desktop/表格识别)")
    parser.add_argument("--output-json", help="Where to save JSON result")
    parser.add_argument("--output-excel", help="Where to save decoded Excel result")
    parser.add_argument("--return-excel", choices=["true", "false"], help="Whether to request excel_file")
    parser.add_argument("--cell-contents", choices=["true", "false"], help="Whether to request cell contents polygons")
    parser.add_argument("--listen-hotkey", action="store_true", help="Listen for a global hotkey and capture a screenshot")
    parser.add_argument("--hotkey", help=f"Global hotkey for screenshot capture (default: {DEFAULT_HOTKEY})")
    parser.add_argument("--access-token", help="Use an existing access_token directly")
    parser.add_argument("--api-key", help="Baidu API Key")
    parser.add_argument("--secret-key", help="Baidu Secret Key")
    parser.add_argument("--table-url", help="Override OCR endpoint URL")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    env_file = Path(args.env_file)
    config = merge_config(env_file)

    input_file_raw = (args.input_file or config.get("BAIDU_OCR_INPUT_FILE", "")).strip()
    input_url = (args.input_url or config.get("BAIDU_OCR_INPUT_URL", "")).strip() or None
    page_num_raw = args.page_num or config.get("BAIDU_OCR_PAGE_NUM", "").strip() or None
    return_excel = str_to_bool(args.return_excel or config.get("BAIDU_OCR_RETURN_EXCEL"), default=True)
    cell_contents = str_to_bool(args.cell_contents or config.get("BAIDU_OCR_CELL_CONTENTS"), default=True)
    access_token = args.access_token or config.get("BAIDU_OCR_ACCESS_TOKEN", "").strip()
    api_key = args.api_key or config.get("BAIDU_OCR_API_KEY", "").strip()
    secret_key = args.secret_key or config.get("BAIDU_OCR_SECRET_KEY", "").strip()
    table_url = args.table_url or config.get("BAIDU_OCR_TABLE_URL", TABLE_URL)
    hotkey = args.hotkey or config.get("BAIDU_OCR_CAPTURE_HOTKEY", DEFAULT_HOTKEY)

    input_provided = bool(input_file_raw or input_url)
    listen_hotkey = args.listen_hotkey or (
        str_to_bool(config.get("BAIDU_OCR_LISTEN_HOTKEY"), default=not input_provided)
    )

    page_num = int(page_num_raw) if page_num_raw else None
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    _output_dir, output_json, output_excel = resolve_output_paths(args, config, timestamp)

    temporary_capture: Path | None = None
    try:
        if listen_hotkey and not input_url and not input_file_raw:
            temporary_capture = capture_screenshot_via_hotkey(hotkey)
            input_file = temporary_capture
        else:
            input_file = Path(input_file_raw).expanduser() if input_file_raw else None

        if not access_token:
            if not api_key or not secret_key:
                raise SystemExit(
                    "Missing credentials: please set BAIDU_OCR_ACCESS_TOKEN or both BAIDU_OCR_API_KEY and BAIDU_OCR_SECRET_KEY."
                )
            access_token = get_access_token(api_key, secret_key)

        payload = build_payload(input_file, input_url, page_num, return_excel, cell_contents)
        request_url = f"{table_url}?access_token={access_token}"
        body = urlencode(payload).encode("utf-8")
        result = http_post_json(
            request_url,
            headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
            data=body,
        )

        save_json(output_json, result)
        excel_saved = save_excel_if_present(output_excel, result) if return_excel else False

        print("Baidu Table OCR request finished.")
        print(f"- output json: {output_json.resolve()}")
        if excel_saved:
            print(f"- output excel: {output_excel.resolve()}")
        elif return_excel:
            print("- excel_file not present in response")
        print(f"- log_id: {result.get('log_id')}")
        print(f"- table_num: {result.get('table_num')}")

        if "error_code" in result:
            print(json.dumps(result, ensure_ascii=False, indent=2), file=sys.stderr)
            return 1
        return 0
    finally:
        if temporary_capture and temporary_capture.exists():
            try:
                temporary_capture.unlink()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
