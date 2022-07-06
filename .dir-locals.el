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
                   (setenv "CONFIG_NAME" "dev")))))
 (nim-mode . ((nim-compile-default-command . ("r" "-r" "--gc:arc" "--threads:on" "--deepcopy:on" "--verbosity:0" "--hint[Processing]:off" "--excessiveStackTrace:on"))
              (lsp-nim-nimsuggest-mapping . [(:projectFile "tests/all.nim" :fileRegex "tests/.*\\.nim")
                                             (:projectFile "src/nim/server.nim" :fileRegex "src/nim/.*|.*.nim$")]))))
