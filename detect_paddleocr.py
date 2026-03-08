import os
import sys
import time
import traceback
from pathlib import Path

os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

import paddle
from paddleocr import PaddleOCR, __version__ as paddleocr_version

SUPPORTED_SUFFIXES = {".png", ".jpg", ".jpeg"}
PREFERRED_NAMES = ["test.png", "test.jpg", "test.jpeg"]
OUTPUT_TXT = Path("detect_result.txt")


def find_image() -> Path | None:
    cwd = Path.cwd()
    for name in PREFERRED_NAMES:
        p = cwd / name
        if p.exists() and p.is_file():
            return p
    images = sorted(
        [p for p in cwd.iterdir() if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIXES],
        key=lambda p: p.name,
    )
    return images[0] if images else None


def main() -> int:
    lines = []
    lines.append(f"paddle version: {paddle.__version__}")
    lines.append(f"cuda available: {paddle.device.is_compiled_with_cuda()}")
    lines.append(f"paddleocr version: {paddleocr_version}")

    image_path = find_image()
    if image_path is None:
        lines.append("未找到当前目录下的 png/jpg/jpeg 图片。")
        OUTPUT_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines))
        print(f"\n结果已写入: {OUTPUT_TXT.resolve()}")
        return 1

    lines.append(f"image path: {image_path.resolve()}")
    start = time.perf_counter()
    ocr = PaddleOCR(lang="ch", device="cpu")
    results = ocr.predict(str(image_path))
    elapsed = time.perf_counter() - start

    first = results[0] if isinstance(results, list) and results else results
    rec_texts = list(first.get("rec_texts", [])) if first else []
    rec_scores = list(first.get("rec_scores", [])) if first else []

    lines.append(f"elapsed_s: {elapsed:.4f}")
    lines.append(f"text_boxes: {len(rec_texts)}")
    lines.append("texts:")
    for idx, text in enumerate(rec_texts, start=1):
        score = rec_scores[idx - 1] if idx - 1 < len(rec_scores) else None
        if score is None:
            lines.append(f"[{idx}] {text}")
        else:
            lines.append(f"[{idx}] {text} (score={score:.4f})")

    OUTPUT_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    print(f"\n结果已写入: {OUTPUT_TXT.resolve()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        msg = f"检测脚本运行失败: {e}"
        print(msg, file=sys.stderr)
        traceback.print_exc()
        try:
            OUTPUT_TXT.write_text(msg + "\n", encoding="utf-8")
        except Exception:
            pass
        raise SystemExit(1)
