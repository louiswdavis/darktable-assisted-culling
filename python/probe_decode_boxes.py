"""Ticket 49's check: does a frame's detection differ between the embedded-JPEG draft decode
(tagging, and culling with Fast JPEG on) and the full RAW decode (culling with Fast JPEG off)?

Run with: python python/probe_decode_boxes.py <detector .onnx> <frame> [<frame> ...]
Prints one row per frame and a verdict. Nothing is read from or written to the detection cache."""

import sys

from vehicle_detect import boxes_in, decode_rgb, detect, load_detector

MIN_SCORE = 0.3  # boxes this strong are compared; weaker candidates are never used by either plugin
MIN_IOU = 0.95
MAX_SCORE_GAP = 0.02


def iou(a, b) -> float:
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    return w * h / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - w * h)


def main(model_path: str, frames: list) -> int:
    detector = load_detector(model_path)
    differing = 0
    print("frame | draft boxes | raw boxes | worst IoU | worst score gap | same")
    for frame in frames:
        # both sets in a unit square, so the two decodes' different pixel sizes compare directly
        draft, raw = ([b for b in boxes_in(detect(decode_rgb(frame, fast), detector), 1, 1) if b[4] >= MIN_SCORE]
                      for fast in (True, False))
        worst_iou, worst_gap = 1.0, 0.0
        for box in draft:
            mate = max(raw, key=lambda r: iou(box, r), default=None)
            worst_iou = min(worst_iou, iou(box, mate) if mate else 0.0)
            worst_gap = max(worst_gap, abs(box[4] - mate[4]) if mate else 1.0)
        same = len(draft) == len(raw) and worst_iou >= MIN_IOU and worst_gap <= MAX_SCORE_GAP
        differing += not same
        print(f"{frame} | {len(draft)} | {len(raw)} | {worst_iou:.3f} | {worst_gap:.3f} | {'yes' if same else 'NO'}")
    print(f"{len(frames) - differing} of {len(frames)} frames the same "
          f"(IoU >= {MIN_IOU}, score within {MAX_SCORE_GAP}, boxes scoring {MIN_SCORE} or more)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
