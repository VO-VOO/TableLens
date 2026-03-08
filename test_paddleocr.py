import os
import sys
import tempfile
import traceback
from pathlib import Path

os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

import paddle
from paddleocr import PaddleOCR, __version__ as paddleocr_version

try:
    from PIL import Image
except Exception:
    Image = None

SUPPORTED_SUFFIXES = {".png", ".jpg", ".jpeg"}
PREFERRED_NAMES = ["test.png", "test.jpg", "test.jpeg"]
OUTPUT_TXT = Path("paddleocr_result.txt")


def find_image() -> Path | None:
    cwd = Path.cwd()

    for name in PREFERRED_NAMES:
        p = cwd / name
        if p.exists() and p.is_file():
            return p

    candidates = sorted(
        [
            p
            for p in cwd.iterdir()
            if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIXES
        ],
        key=lambda p: p.name,
    )
    return candidates[0] if candidates else None


def summarize_texts(texts, scores):
    lines = []
    lines.append(f"检测到文本框数量: {len(texts)}")
    if not texts:
        lines.append("OCR 已执行，但未识别到文本。")
        return lines

    lines.append("识别结果摘要:")
    for idx, text in enumerate(texts[:20], start=1):
        score = scores[idx - 1] if idx - 1 < len(scores) else None
        if score is None:
            lines.append(f"{idx}. {text}")
        else:
            lines.append(f"{idx}. {text} (score={score:.4f})")

    if len(texts) > 20:
        lines.append(f"... 其余 {len(texts) - 20} 条结果已省略")

    lines.append("")
    lines.append("完整识别文本:")
    for idx, text in enumerate(texts, start=1):
        lines.append(f"[{idx}] {text}")
    return lines


def run_ocr_on_path(ocr: PaddleOCR, image_path: Path):
    return ocr.predict(str(image_path))


def maybe_retry_with_png(ocr: PaddleOCR, image_path: Path, exc: Exception):
    if image_path.suffix.lower() not in {".jpg", ".jpeg"}:
        raise exc
    if Image is None:
        raise exc

    with tempfile.TemporaryDirectory() as tmpdir:
        converted = Path(tmpdir) / "converted_from_jpg.png"
        Image.open(image_path).convert("RGB").save(converted)
        return run_ocr_on_path(ocr, converted), converted


def main() -> int:
    lines = []
    lines.append(f"paddle version: {paddle.__version__}")
    lines.append(f"cuda available: {paddle.device.is_compiled_with_cuda()}")
    lines.append(f"paddleocr version: {paddleocr_version}")

    image_path = find_image()
    if image_path is None:
        lines.append("未找到当前目录下的 png/jpg/jpeg 图片。请放入图片后重跑。")
        OUTPUT_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines))
        print(f"\n结果已写入: {OUTPUT_TXT.resolve()}")
        return 0

    lines.append(f"image path: {image_path.resolve()}")
    lines.append("开始执行中文 OCR（CPU-only）。首次运行可能会自动下载模型，请稍等。")

    ocr = PaddleOCR(lang="ch", device="cpu")

    converted_path = None
    try:
        results = run_ocr_on_path(ocr, image_path)
    except Exception as e:
        lines.append(f"原始图片直接识别失败，尝试转 PNG 重试: {e}")
        results, converted_path = maybe_retry_with_png(ocr, image_path, e)

    if isinstance(results, list) and results:
        first = results[0]
    else:
        first = results

    rec_texts = list(first.get("rec_texts", [])) if first else []
    rec_scores = list(first.get("rec_scores", [])) if first else []

    if converted_path is not None:
        lines.append(f"fallback png path: {converted_path}")

    lines.extend(summarize_texts(rec_texts, rec_scores))

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
        msg = f"OCR 运行失败: {e}"
        print(msg, file=sys.stderr)
        traceback.print_exc()
        try:
            OUTPUT_TXT.write_text(msg + "\n", encoding="utf-8")
        except Exception:
            pass
        raise SystemExit(1)
