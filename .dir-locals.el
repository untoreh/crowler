;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (eval . (setq pyvenv-activate
                       (my/concat-path
                        (python-repl-current-project-dir)
                        ".venv")))
         (eval . (progn
                   (setenv "PROJECT_DIR"
                           (projectile-project-root))
                   (setenv "CONFIG_NAME" "dev")
                   (setenv "DOCKER" nil)
                   (setenv "LIBPYTHON_PATH" nil)))))
 (nim-mode . ((nim-compile-default-command . ("r" "-r"))
              (lsp-nim-project-mapping . [(:projectFile "tests/all.nim" :fileRegex "tests/.*\\.nim")
                                          (:projectFile "src/nim/server.nim" :fileRegex "src/nim/.*|.*\\.nim")
                                          (:projectFile "src/nim/test.nim" :fileRegex "src/nim/test.*\\.nim")])
              (projectile-project-compilation-cmd . "nim r tests/test_server.nim"))))
