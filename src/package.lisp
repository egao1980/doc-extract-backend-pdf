(defpackage #:doc-extract-backend-pdf
  (:use #:cl #:cffi #:doc-extract-protocol)
  (:export #:pdf-doc-extract-backend
           #:make-pdf-doc-extract-backend
           #:use-pdf-doc-extract-backend
           #:pdf-cffi-library-path
           #:pdf-driver
           #:pdf-driver-loaded-p
           #:pdf-password

           #:pdfium-not-loaded
           #:pdfium-available-p
           #:load-pdfium
           #:libpdfium
           #:*pdfium-fn-table*
           #:+pdfium-extractor-priority+

           #:render-page
           #:pdf-page-not-found
           #:pdf-page-not-found-index
           #:pdf-page-not-found-page-count))

(in-package #:doc-extract-backend-pdf)
