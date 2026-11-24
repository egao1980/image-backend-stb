(defsystem "image-backend-stb"
  :version "0.3.0"
  :description "image-protocol backend on stb_image / stb_image_write (vendored with Fedora's security patches), plus a native resize fast path on stb_image_resize2"
  :author "egao1980"
  :license "MIT"
  :defsystem-depends-on ("asdf-native")
  :depends-on ((:version "image-protocol" "0.3.0") "cffi" "uiop")
  :serial t
  :pathname "src"
  :components ((:file "package")
               ;; $STB_CL_NATIVE, native/ (overlay), lib/<os>-<arch>/ (checkout)
               (:native-library "stb-cl")
               (:file "backend")
               (:file "resize"))
  :in-order-to ((test-op (test-op "image-backend-stb/tests")))
  ;; Overlays: lib/<os>-<arch>/ per platform, from the :native-library components.
  :properties (:cl-repo (:provides ("image-backend-stb"))))

(defsystem "image-backend-stb/tests"
  :depends-on ("image-backend-stb" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test")
               (:file "resize-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
