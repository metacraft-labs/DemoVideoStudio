# Codec study

The scripts behind DemoVideoScript-pm `spec/Codec-Study.md`. They are kept so the
numbers can be measured again, for example with a new encoder or browser.

| File | What it measures |
|---|---|
| `blur.py <still.png> <work dir>` | Each step that made the first videos blurred, applied alone to one lossless still (SSIM and PSNR on text crops) |
| `codec.py <work dir> <stills dir> [candidate…]` | Each candidate encode of a clip of stills (size, encode time, SSIM on text crops); writes `codec.json` |
| `play.html?files=[…]`, served by `server.py <port>` | Whether a browser plays each file, and the frames it presents and drops over 10 s; POSTs its results to the server |
| `fidelity.html?files=[…]` | One decoded frame read back through a canvas and compared with `ref010.png` (PSNR) |

The stills are a run's step captures (PNG, at the window's size).
