#!/usr/bin/env python3
import logging, sys, os
from io import BytesIO, StringIO

logger = logging.getLogger()
logger_level = getattr(logging, os.getenv("PYTHON_DEBUG", "info").upper())

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter("%(name)s - %(levelname)s - %(message)s"))
logger.addHandler(handler)


def setloglevel(logger=logger, lvl=logger_level):
    logger.setLevel(lvl)
    for h in logger.handlers:
        h.setLevel(lvl)


setloglevel()
# Shut up httpx errors
setloglevel(logging.getLogger("httpx"), lvl=logging.CRITICAL)
DEFAULT_LEVELS = {}


# NOTE: This only works with async code
class LoggerLevel(object):
    def __init__(
        self, logger=logger, level: None | int = logging.CRITICAL, quiet=False
    ):
        self.logger: logging.Logger = logger
        self.quiet = quiet
        self.on_level = level
        self.null = None
        self.stdout = None
        self.stderr = None

    def __call__(self):
        return self

    def __enter__(self):
        if self.logger:
            if self.logger not in DEFAULT_LEVELS:
                DEFAULT_LEVELS[self.logger] = self.logger.level
            for h in self.logger.handlers:
                if h not in DEFAULT_LEVELS:
                    DEFAULT_LEVELS[h] = h.level
            if not self.quiet:
                setloglevel(self.logger, self.on_level)
            else:
                self.null = StringIO()
                self.stdout = sys.stdout
                self.stderr = sys.stderr
                sys.stdout, sys.stderr = self.null

    def __exit__(self, *_):
        if self.logger:
            try:
                self.logger.setLevel(DEFAULT_LEVELS[self.logger])
            except KeyError:
                pass
            try:
                for h in self.logger.handlers:
                    if h in DEFAULT_LEVELS:
                        h.setLevel(DEFAULT_LEVELS[h])
            except KeyError:
                pass
            if self.quiet:
                if isinstance(self.null, BytesIO):
                    self.null.close()
                sys.stdout = self.stdout
                sys.stderr = self.stderr


def warn(*args, **kwargs):
    logger.warning(*args, **kwargs)


def info(*args, **kwargs):
    logger.info(*args, **kwargs)


def debug(*args, **kwargs):
    logger.debug(*args, **kwargs)
