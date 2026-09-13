# doc-extract-backend-pdf

[`doc-extract-protocol`](https://github.com/egao1980/doc-extract-protocol) backend for **PDF** via [PDFium](https://pdfium.googlesource.com/pdfium/) (`libpdfium`) CFFI.

This checkout does **not** vendor a pdfium build (hundreds of MB). Tests pass without the native library: missing `libpdfium` is a soft load failure; the GFs signal `pdfium-not-loaded` (a `doc-extract-unsupported`) with `use-value` / `retry`.

```lisp
(asdf:load-system "doc-extract-backend-pdf")

(let ((b (doc-extract-backend-pdf:make-pdf-doc-extract-backend)))
  (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                  (lambda (c) (use-value "" c))))
    (doc-extract-protocol:extract-text b #p"x.pdf" :format :pdf)))
```

## API

| Binding | Role |
|---------|------|
| `pdf-doc-extract-backend` | CLOS class (`doc-extract-backend`) |
| `make-pdf-doc-extract-backend` | `&key cffi-library-path driver password` |
| `use-pdf-doc-extract-backend` | bind `*doc-extract-backend*` |
| `extract-text` / `extract-metadata` / `extract-sections` | protocol GFs |
| `pdfium-available-p` / `load-pdfium` | native probe (never crashes ASDF) |
| `*pdfium-fn-table*` | optional FPDF_* stand-in plist (tests) |
| `pdf-driver` | kafka-style GF table (`:extract-text` …) |

Source may be a pathname, a filesystem string, a `%PDF…` string, or an `(unsigned-byte 8)` vector.

`extract-metadata` is a plist (`:format :pdf`, `:page-count`, plus cheap `FPDF_GetMetaText` tags when present: `:title` `:author` `:subject` `:keywords` `:creator` `:producer` `:creation-date` `:mod-date`). `extract-sections` is one `extracted-section` per page (`"Page N"`).

CFFI subset: `FPDF_InitLibrary` / `FPDF_DestroyLibrary`, `FPDF_LoadMemDocument` / `FPDF_LoadDocument` / `FPDF_CloseDocument`, `FPDF_GetPageCount` / `FPDF_LoadPage` / `FPDF_ClosePage`, `FPDFText_LoadPage` / `FPDFText_CountChars` / `FPDFText_GetText` / `FPDFText_ClosePage`, `FPDF_GetMetaText` (+ `FPDF_GetLastError`).

## Load strategy

Absolute-path `cffi:load-foreign-library` only. **Never** `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`. `load-foreign-library` is not called unless a file was `probe-file`'d (kafka rule). Search order:

1. Backend slot `cffi-library-path` (at GF time)
2. Env `PDFIUM_LIBRARY` (absolute file)
3. Overlay dest: `native/` and `lib/<os>-<arch>/` next to the ASDF system (plus optional dir `PDFIUM_NATIVE`)

ASDF load calls `load-pdfium` and swallows a miss (`warn`). Consumers `(asdf:load-system "doc-extract-backend-pdf")` — no `ensure-*` helper required when the overlay is present.

Inject a driver so unit tests never `dlopen`:

```lisp
(doc-extract-backend-pdf:make-pdf-doc-extract-backend
 :driver (list :extract-text (lambda (backend source &key format)
                               (declare (ignore backend source format))
                               "hello")))
```

Or bind `*pdfium-fn-table*` to a plist of FPDF_* functions and exercise the real extract loop without a native lib.

## Native overlay

`.asd` `:cl-repo` lists expected sonames even when binaries are not in-tree:

| Platform | Inventory |
|----------|-----------|
| linux/amd64, linux/arm64 | `libpdfium.so`, `libpdfium.so.1` |
| darwin/arm64 | `libpdfium.dylib`, `libpdfium.1.dylib` |
| windows/amd64 | `pdfium.dll`, `libpdfium.dll` |

Stage locally into `lib/<os>-<arch>/` (gitignored) or set `PDFIUM_LIBRARY`. Do not commit a Chromium-sized pdfium tree.

### Publishing overlays (`publish-oci.yml` shape)

Same owning-repo native publish as [`llama-cpp`](https://github.com/egao1980/llama-cpp):

1. Per-platform job stages `libpdfium` into `native-bundle/` (download a prebuilt shared lib or a thin wrapper — **do not** check the binary into git).
2. Upload `native-<os>-<arch>` artifacts.
3. A `publish` job calls `egao1980/cl-repository/.github/workflows/publish-native-package.yml@main` with `package-name: doc-extract-backend-pdf` and `source-paths` of the `.asd`, `src`, `LICENSE`, `README.md`. The packager honors `:cl-repo` `:overlays` (not a parallel YAML inventory).
4. Consumers resolve the overlay via cl-repository; this library absolute-preloads the staged file.

Sketch (llama-cpp / `event-backend-libuv` shape):

```yaml
# .github/workflows/publish-oci.yml
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version: { required: false, default: "" }
      registry: { required: false, default: "ghcr.io" }

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: linux,  arch: amd64, runner: ubuntu-latest }
          - { os: linux,  arch: arm64, runner: ubuntu-24.04-arm }
          - { os: darwin, arch: arm64, runner: macos-latest }
          - { os: windows, arch: amd64, runner: windows-latest }
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v5
      # Stage lib/<os>-<arch>/libpdfium* → native-bundle/ (script TBD).
      - uses: actions/upload-artifact@v6
        with: { name: native-${{ matrix.os }}-${{ matrix.arch }}, path: native-bundle/ }

  publish:
    needs: [build, resolve-version]
    uses: egao1980/cl-repository/.github/workflows/publish-native-package.yml@main
    with:
      package-name: doc-extract-backend-pdf
      version: ${{ needs.resolve-version.outputs.version }}
      registry: ${{ inputs.registry || 'ghcr.io' }}
      source-paths: |
        doc-extract-backend-pdf.asd
        src
        LICENSE
        README.md
```

Source-only Lisp still publishes via `publish-checkout.yml` → `publish-source.yml@main`. Overlay binaries carry pdfium's own license (BSD-3-Clause); keep them out of this MIT Lisp tree.

## Tests

`asdf:test-system "doc-extract-backend-pdf"` is green without `libpdfium`. A live extract is skipped unless `pdfium-available-p`.

## License

MIT — see [LICENSE](LICENSE).
