;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (eval . (setq pyvenv-activate
                       (my/concat-path
                        (python-repl-current-project-dir)
                        ".venv"))))))
