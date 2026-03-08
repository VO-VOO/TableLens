import os
from pathlib import Path

os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

from PIL import Image
from paddleocr import PaddleOCR

SRC = Path('/Users/utolaris/Documents/ai/paddle/截屏2026-03-08 10.54.09.png')
SCALES = [50, 75, 100]
OUT_DIR = Path('/Users/utolaris/Documents/ai/paddle/scaled_ocr_outputs')
OUT_DIR.mkdir(exist_ok=True)


def run_once(ocr, image_path: Path):
    results = ocr.predict(str(image_path))
    first = results[0] if isinstance(results, list) and results else results
    rec_texts = list(first.get('rec_texts', [])) if first else []
    rec_scores = list(first.get('rec_scores', [])) if first else []
    return rec_texts, rec_scores


def main():
    img = Image.open(SRC).convert('RGB')
    ocr = PaddleOCR(lang='ch', device='cpu')

    for scale in SCALES:
        if scale == 100:
            scaled_path = SRC
        else:
            w = max(1, round(img.width * scale / 100))
            h = max(1, round(img.height * scale / 100))
            resized = img.resize((w, h), Image.Resampling.LANCZOS)
            scaled_path = OUT_DIR / f'{SRC.stem}_{scale}pct.png'
            resized.save(scaled_path)

        rec_texts, rec_scores = run_once(ocr, scaled_path)
        txt_path = Path('/Users/utolaris/Documents/ai/paddle') / f'ocr_{scale}pct.txt'

        lines = []
        lines.append(f'source_image: {SRC}')
        lines.append(f'scale_pct: {scale}')
        lines.append(f'ocr_input: {scaled_path}')
        lines.append(f'text_boxes: {len(rec_texts)}')
        lines.append('texts:')
        for i, text in enumerate(rec_texts, start=1):
            score = rec_scores[i - 1] if i - 1 < len(rec_scores) else None
            if score is None:
                lines.append(f'[{i}] {text}')
            else:
                lines.append(f'[{i}] {text} (score={score:.4f})')

        txt_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        print(f'Wrote: {txt_path}')


if __name__ == '__main__':
    main()
