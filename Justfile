## Justfile - DemoVideoStudio.
##
## The siblings named in .github/sibling-repos come from checkouts next to this
## one, or the *_SRC variables: GuiAssert (capture, ffmpeg helpers),
## DemoVideoScript (the scenario model, linter, runner and protocol), and the
## terminal flavour the editor's suites pick through (DemoVideoScript-TermAssert
## and what it builds on). Build outputs go under BUILD_DIR.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test

build_dir := env_var_or_default("BUILD_DIR", "build")
nim_flags := "--hints:off --passC:-w --threads:on"
dvs_src := env_var_or_default("DVS_SRC", "../DemoVideoScript/src")
dvs_root := dvs_src / ".."
ta_root := env_var_or_default("DVS_TERMASSERT_ROOT", "../DemoVideoScript-TermAssert")
ta_paths := "--path:" + ta_root + "/src --path:" + dvs_src + " --path:" + env_var_or_default("TERM_ASSERT_SRC", "../TermAssert/src") + " --path:" + env_var_or_default("NIM_PTY_SRC", "../nim-pty/src") + " --path:" + env_var_or_default("NIM_LIBVTERM_SRC", "../nim-libvterm/src") + " --path:" + env_var_or_default("TERM_ASSERT_CLIENT_SRC", "../TermAssertClient/src")
pw_root := env_var_or_default("DVS_PLAYWRIGHT_ROOT", "../DemoVideoScript-Playwright")
flavours := build_dir / "flavours"
# the flavours the suites pick, run and render through
flavour_env := "DVS_TERMINAL_HOST=" + flavours + "/dvs-termassert-notes DVS_NOTES_TUI=" + flavours + "/notes-tui DVS_ROOT=" + dvs_root + " DVS_PLAYWRIGHT_ROOT=" + pw_root + " DVS_NOTES_WEB=" + flavours + "/web"
suites := "tscenario_editor tscenario_ui trender tplugin_contract tsilent_render tparser tmedia tspeech_synthesis ttalking_head temotive tdiscovery tartifact_project tartifact_pipeline teditor tdriver_browser tdriver_vscode tdriver_storyboard"

# The moved suites, unchanged in what they check: composition through a real
# ffmpeg, the editor's HTTP surface, the artifact pipeline, the keyframe-script
# parser and driver, narration and the presenter overlay without a provider.
test: build-flavours
    @mkdir -p {{build_dir}}/test-bin
    @for f in {{suites}}; do \
      echo "===== $f ====="; \
      {{flavour_env}} nim c -r {{nim_flags}} --nimcache:{{build_dir}}/nimcache/$f -o:{{build_dir}}/test-bin/$f tests/$f.nim || exit 1; \
    done

# The flavours: DemoVideoScript-TermAssert's JSON-lines host with the
# conformance binding and the application's terminal build; and
# DemoVideoScript-Playwright's host (node) with the application's web build.
# The Playwright checkout gets the dev shell's playwright-core linked into its
# node_modules, as its own `just setup` does.
build-flavours:
    @mkdir -p {{flavours}}/web {{pw_root}}/node_modules
    nim c {{nim_flags}} --mm:orc -d:release {{ta_paths}} --nimcache:{{build_dir}}/nimcache/flavour-terminal -o:{{flavours}}/dvs-termassert-notes {{ta_root}}/conformance/dvs_termassert_notes.nim
    nim c {{nim_flags}} --mm:orc -d:release --nimcache:{{build_dir}}/nimcache/notes-tui -o:{{flavours}}/notes-tui {{dvs_root}}/conformance/app/notes_tui.nim
    nim js --hints:off -d:release --nimcache:{{build_dir}}/nimcache/notes-web -o:{{flavours}}/web/notes_web.js {{dvs_root}}/conformance/app/notes_web.nim
    cp {{dvs_root}}/conformance/app/web/index.html {{flavours}}/web/index.html
    ln -sfn "$DVS_PLAYWRIGHT_CORE" {{pw_root}}/node_modules/playwright-core

# `dvs-studio`, the command line.
build:
    @mkdir -p {{build_dir}}/bin
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/dvs-studio -o:{{build_dir}}/bin/dvs-studio src/dvs_studio.nim

# A mutation harness: `just mutate dvs10`.
mutate name: build-flavours
    {{flavour_env}} python3 tests/mutation/run-{{name}}-mutations.py

lint: lint-nim lint-nix

lint-nim:
    @for f in {{suites}}; do nim check {{nim_flags}} tests/$f.nim || exit 1; done

lint-nix:
    nixfmt --check flake.nix

format:
    nixfmt flake.nix

clean:
    rm -rf {{build_dir}}
