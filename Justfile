## Justfile - DemoVideoStudio.
##
## GuiAssert (capture, ffmpeg helpers, the PTY) comes from the checkout named in
## .github/sibling-repos next to this one, or GUI_ASSERT_SRC. Build outputs go
## under BUILD_DIR.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test

build_dir := env_var_or_default("BUILD_DIR", "build")
nim_flags := "--hints:off --passC:-w"
suites := "tplugin_contract tparser tmedia tspeech_synthesis ttalking_head temotive tdiscovery tartifact_project tartifact_pipeline teditor tdriver_browser tdriver_vscode tdriver_storyboard"

# The moved suites, unchanged in what they check: composition through a real
# ffmpeg, the editor's HTTP surface, the artifact pipeline, the keyframe-script
# parser and driver, narration and the presenter overlay without a provider.
test:
    @mkdir -p {{build_dir}}/test-bin
    @for f in {{suites}}; do \
      echo "===== $f ====="; \
      nim c -r {{nim_flags}} --nimcache:{{build_dir}}/nimcache/$f -o:{{build_dir}}/test-bin/$f tests/$f.nim || exit 1; \
    done

lint: lint-nim lint-nix

lint-nim:
    @for f in {{suites}}; do nim check {{nim_flags}} tests/$f.nim || exit 1; done

lint-nix:
    nixfmt --check flake.nix

format:
    nixfmt flake.nix

clean:
    rm -rf {{build_dir}}
