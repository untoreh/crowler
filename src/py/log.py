#!/usr/bin/env python3
import logging, sys, os
from io import StringIO

logger = logging.getLogger()
logger_level = getattr(logging, os.getenv("PYTHON_DEBUG", "warning").upper())

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter("%(name)s - %(levelname)s - %(message)s"))
logger.addHandler(handler)


def setloglevel(logger=logger, lvl=logger_level):
    logger.setLevel(lvl)
    for h in logger.handlers:
        h.setLevel(lvl)


setloglevel()


class LoggerLevel(object):
    def __init__(self, logger=logger, level=logging.CRITICAL, quiet=False):
        self.logger: logging.Logger = logger
        self.quiet = quiet
        self.on_level = level
        self.root_lvl = None
        self.handlers_lvl = []
        self.null = None
        self.stdout = None
        self.stderr = None

    def __call__(self):
        return self

    def __enter__(self):
        if self.logger:
            self.root_lvl = self.logger.level
            self.handlers_lvl = [h.level for h in self.logger.handlers]
            if not self.quiet:
                setloglevel(self.logger, self.on_level)
            else:
                self.null = StringIO()
                self.stdout = sys.stdout
                self.stderr = sys.stderr
                sys.stdout, sys.stderr = self.null

    def __exit__(self, *_):
        if self.logger and self.root_lvl:
            self.logger.setLevel(self.root_lvl)
            for (lv, h) in zip(self.handlers_lvl, self.logger.handlers):
                h.setLevel(lv)
            if self.quiet:
                self.null.close()
                sys.stdout = self.stdout
                sys.stderr = self.stderr


def warn(*args, **kwargs):
    logger.warning(*args, **kwargs)


def info(*args, **kwargs):
    logger.info(*args, **kwargs)


def debug(*args, **kwargs):
    logger.debug(*args, **kwargs)
