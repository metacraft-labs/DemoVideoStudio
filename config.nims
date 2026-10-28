# The package's sources, and GuiAssert's (capture, ffmpeg helpers, the PTY),
# on the Nim path, so the tests run as plain `nim c -r tests/x.nim`.
# GuiAssert is the sibling checkout `../GuiAssert` unless GUI_ASSERT_SRC
# names its `src`.
switch("path", "src")
switch("path", getEnv("GUI_ASSERT_SRC", thisDir() & "/../GuiAssert/src"))
