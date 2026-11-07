(defsystem "image-backend-stb"
  :version "0.1.0"
  :description "image-protocol backend on stb_image / stb_image_write (vendored with Fedora's security patches)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("image-protocol" "cffi" "uiop")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "loader")
               (:file "backend"))
  :in-order-to ((test-op (test-op "image-backend-stb/tests")))
  :properties
  (:cl-repo
   (:cffi-libraries ("libstb-cl")
    :provides ("image-backend-stb")
    :overlays
    ((:platform (:os "linux" :arch "amd64")
      :layers ((:role "native-library" :files (("lib/linux-amd64/libstb-cl.so" . "libstb-cl.so")))))
     (:platform (:os "linux" :arch "arm64")
      :layers ((:role "native-library" :files (("lib/linux-arm64/libstb-cl.so" . "libstb-cl.so")))))
     (:platform (:os "darwin" :arch "arm64")
      :layers ((:role "native-library" :files (("lib/darwin-arm64/libstb-cl.dylib" . "libstb-cl.dylib")))))
     (:platform (:os "windows" :arch "amd64")
      :layers ((:role "native-library" :files (("lib/windows-amd64/stb-cl.dll" . "stb-cl.dll")))))))))

(defsystem "image-backend-stb/tests"
  :depends-on ("image-backend-stb" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
