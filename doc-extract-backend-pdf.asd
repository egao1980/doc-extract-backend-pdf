(defsystem "doc-extract-backend-pdf"
  :version "0.1.0"
  :description "pdfium CFFI backend for doc-extract-protocol"
  :author "egao1980"
  :license "MIT"
  :depends-on ("cffi" "doc-extract-protocol")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "ffi")
               (:file "backend"))
  :in-order-to ((test-op (test-op "doc-extract-backend-pdf/tests")))
  :properties
  (:cl-repo
   (:cffi-libraries ("libpdfium")
    :provides ("doc-extract-backend-pdf")
    :overlays
    ((:platform (:os "linux" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/linux-amd64/libpdfium.so" . "libpdfium.so")
                        ("lib/linux-amd64/libpdfium.so.1" . "libpdfium.so.1")))))
     (:platform (:os "linux" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/linux-arm64/libpdfium.so" . "libpdfium.so")
                        ("lib/linux-arm64/libpdfium.so.1" . "libpdfium.so.1")))))
     (:platform (:os "darwin" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/darwin-arm64/libpdfium.dylib" . "libpdfium.dylib")
                        ("lib/darwin-arm64/libpdfium.1.dylib" . "libpdfium.1.dylib")))))
     (:platform (:os "windows" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/windows-amd64/pdfium.dll" . "pdfium.dll")
                        ("lib/windows-amd64/libpdfium.dll" . "libpdfium.dll")))))))))

(defsystem "doc-extract-backend-pdf/tests"
  :depends-on ("doc-extract-backend-pdf" "cffi" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
