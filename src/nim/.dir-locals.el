((nim-mode . ((nim-compile-default-command . ("r" "-r" "--gc:arc" "--threads:on" "--deepcopy:on" "--verbosity:0" "--hint[Processing]:off" "--excessiveStackTrace:on"))
              ;; (eval . (lsp-register-custom-settings
              ;;          [(:projectFile "translate.nim" :fileRegex ".*\\.nim")]))
              ))
 (lsp-mode . ((lsp-restart . 'auto-restart))))
