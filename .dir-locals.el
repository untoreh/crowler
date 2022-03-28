;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (eval . (setq pyvenv-activate
                       (my/concat-path
                        (python-repl-current-project-dir)
                        ".venv")))
         (nim-compile-default-command . ("r" "-r" "--gc:arc" "--threads:on" "--deepcopy:on" "--verbosity:0" "--hint[Processing]:off" "--excessiveStackTrace:on")))))
