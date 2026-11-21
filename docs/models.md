# Models

Part of [darktable-assisted-culling](../README.md). The recommended download is in [Install, step 4](../README.md#4-models); this page covers the rest.

**Which models culling uses.**

Every model is optional: culling scores without any. There are three jobs, and these are all the models culling uses:

| Job | Used by | Where it lives |
|---|---|---|
| Subject mask (SAM) | the *subject tracking (SAM)* sharpness mode | managed by darktable (below) |
| Vehicle detector | motorsport: SAM's prompt box, *motion-aware* sharpness, burst direction | `models/` in this repo |
| Sharpness judge (HyperIQA) | **Break Close Calls with the Sharpness Judge** only | `models/` in this repo |

`models/` sits next to the venv; `.gitignore` skips the whole folder, so `git pull` leaves it alone. Re-cloning the repo deletes it.


Not in the block on purpose: the other five detectors (`dfine_l`, `rtdetr_v2`, `dfine_m`, `dfine_s`, YOLOX). They're smaller, faster or older steps below D-FINE-X, and the plugin falls back to them only when D-FINE-X isn't installed. Their downloads are in the table below.

Already have the tagging plugin's models? Copy its detector file into this `models` folder instead: the same file shares tagging's detection cache, so frames tagging already detected aren't detected again.

**Subject mask (SAM)** (darktable 5.6+). In darktable, open **preferences → AI**, then enable and download a SAM or SAM 2 mask model. darktable stores and manages it, and the plugin uses whichever mask model is enabled there. SegNext mask models aren't supported; if one is enabled, the run stops and says so.

**Vehicle detector.** The plugin uses the first of these in `models/`, best first, the same order as the tagging plugin. YOLOX runs on OpenCV; the rest need `onnxruntime`. See [Vehicle detector](panel-options.md#vehicle-detector) for what it does.

| File | Size | Download | Notes |
|---|---|---|---|
| `dfine_x_coco.onnx` | 251 MB | `https://huggingface.co/onnx-community/dfine_x_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-X, Apache-2.0. Best; in Recommended. |
| `dfine_l_coco.onnx` | 125 MB | `https://huggingface.co/onnx-community/dfine_l_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-L, Apache-2.0 |
| `rtdetr_v2_r50vd.onnx` | 172 MB | `https://huggingface.co/onnx-community/rtdetr_v2_r50vd-ONNX/resolve/main/onnx/model.onnx` | RT-DETRv2 R50, Apache-2.0 |
| `dfine_m_coco.onnx` | 79 MB | `https://huggingface.co/onnx-community/dfine_m_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-M, Apache-2.0 |
| `dfine_s_coco.onnx` | 42 MB | `https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-S, Apache-2.0 |
| `object_detection_yolox_2022nov.onnx` | 36 MB | `https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx` | YOLOX, Apache-2.0, OpenCV's model zoo. Fastest, misses more cars. |

**Sharpness judge.** Both files, from [86Cao/IQA-ONNX-Models](https://huggingface.co/86Cao/IQA-ONNX-Models) (Apache-2.0). Keep both names: the model looks for the `.data` file by name. Needs `onnxruntime`.

| File | Size | Download |
|---|---|---|
| `hyperiqa_model.onnx` | 0.4 MB | `https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx` |
| `hyperiqa_model.onnx.data` | 109 MB | `https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx.data` |

**Check what's installed.** Each file must be named exactly as above (curl's `-o` does that; a browser download saves `model.onnx`). The run log names the detector it picked, plus any better file you haven't installed, e.g. `vehicle detector: object_detection_yolox_2022nov.onnx (better, not installed: dfine_x_coco.onnx, …)`. A run with the judge setting on and its files missing stops and says so.

**curl says `client returned ERROR on write` (error 23)?** curl got the data but couldn't save it. It isn't because the file already exists: curl overwrites. Either `models/` doesn't exist where you ran it (run from the repo root, or add `--create-dirs` as above), or the file is in use (close darktable, or wait for a run to finish, then retry).
