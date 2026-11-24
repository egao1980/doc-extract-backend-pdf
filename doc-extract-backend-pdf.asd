(defsystem "doc-extract-backend-pdf"
  :version "0.2.0"
  :description "pdfium CFFI backend for doc-extract-protocol: text, metadata, page rasterization"
  :author "egao1980"
  :license "MIT"
  :defsystem-depends-on ((:version "asdf-native" "0.2.0"))
  :depends-on ("cffi" "doc-extract-protocol" "image-protocol")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               ;; $PDFIUM_NATIVE, native/ (overlay), lib/<os>-<arch>/ (checkout).
               ;; Optional: without libpdfium the system still loads (mock-driver CI).
               (:native-library "pdfium" :versions ("1" "0") :optional t)
               (:file "ffi")
               (:file "backend")
               (:file "render"))
  :in-order-to ((test-op (test-op "doc-extract-backend-pdf/tests")))
  ;; Overlays: lib/<os>-<arch>/ per platform, from the :native-library components.
  :properties (:cl-repo (:provides ("doc-extract-backend-pdf"))))

(defsystem "doc-extract-backend-pdf/tests"
  :depends-on ("doc-extract-backend-pdf" "cffi" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test")
               (:file "render-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
