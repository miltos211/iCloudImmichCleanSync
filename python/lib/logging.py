"""
Centralized logging configuration for spotifyToYT project.
Provides consistent logging across all scripts with thread-safe operations.
"""
import logging
import threading
import time
import sys
import os
from pathlib import Path

# Thread-safe print lock for legacy compatibility
print_lock = threading.Lock()

# Global state for current logging configuration
CURRENT_LOG_LEVEL = "INFO"
CURRENT_QUIET = False

class ThreadSafeFormatter(logging.Formatter):
    """Thread-safe formatter that includes thread ID"""
    
    def format(self, record):
        # Add thread ID to the record
        if threading.current_thread() != threading.main_thread():
            thread_id = threading.get_ident() % 1000  # Short thread ID
            record.thread_id = f"T{thread_id}"
        else:
            record.thread_id = "MAIN"
        
        return super().format(record)

def setup_logging(script_name: str, level: str = "INFO", quiet: bool = False):
    """
    Setup centralized logging for a script.
    
    Args:
        script_name: Name of the script (e.g., "spoty_exporter")
        level: Logging level ("DEBUG", "INFO", "WARNING", "ERROR")
        quiet: If True, only log WARNING and above to console
    
    Returns:
        logger: Configured logger instance
    """
    global CURRENT_LOG_LEVEL, CURRENT_QUIET
    
    # Store current configuration for library functions
    CURRENT_LOG_LEVEL = level
    CURRENT_QUIET = quiet
    
    # Create logs directory if it doesn't exist
    log_dir = Path("logs")
    log_dir.mkdir(exist_ok=True)
    
    # Create logger
    logger = logging.getLogger(script_name)
    logger.setLevel(getattr(logging, level.upper()))
    
    # Clear existing handlers to avoid duplicates
    logger.handlers.clear()
    
    # Create formatters
    detailed_formatter = ThreadSafeFormatter(
        fmt='[%(asctime)s] [%(levelname)s] [%(thread_id)s] %(name)s: %(message)s',
        datefmt='%H:%M:%S'
    )
    
    simple_formatter = ThreadSafeFormatter(
        fmt='[%(levelname)s] %(message)s'
    )
    
    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    if quiet:
        console_handler.setLevel(logging.WARNING)
    else:
        # Respect the main script's log level for console output
        console_handler.setLevel(getattr(logging, level.upper()))
    console_handler.setFormatter(simple_formatter)
    logger.addHandler(console_handler)
    
    # File handler for detailed logs
    log_file = log_dir / f"{script_name}.log"
    file_handler = logging.FileHandler(log_file, encoding='utf-8')
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(detailed_formatter)
    logger.addHandler(file_handler)
    
    # Add a filter to prevent duplicate logs from propagating
    logger.propagate = False
    
    return logger

def get_logger(name: str = None) -> logging.Logger:
    """
    Get an existing logger that inherits the current log level from main script.
    
    Args:
        name: Logger name. If None, uses the calling module name
    
    Returns:
        logger: Logger instance with same level as main script
    """
    if name is None:
        # Try to determine caller's module name
        frame = sys._getframe(1)
        name = Path(frame.f_globals.get('__file__', 'unknown')).stem
    
    logger = logging.getLogger(name)
    
    # If logger has no handlers, set up logging using current global configuration
    if not logger.handlers:
        logger = setup_logging(name, level=CURRENT_LOG_LEVEL, quiet=CURRENT_QUIET)
    
    return logger

def thread_safe_print(message: str):
    """
    Thread-safe print function for legacy compatibility.
    Use logger.info() instead when possible.
    """
    with print_lock:
        print(message)

class LoggerAdapter:
    """
    Adapter to make transitioning from print/debug_log easier.
    Provides familiar method names while using proper logging.
    """
    
    def __init__(self, logger_name: str):
        self.logger = get_logger(logger_name)
    
    def info(self, message: str):
        """Log info message"""
        self.logger.info(message)
    
    def debug(self, message: str):
        """Log debug message"""
        self.logger.debug(message)
    
    def warning(self, message: str):
        """Log warning message"""
        self.logger.warning(message)
    
    def error(self, message: str):
        """Log error message"""
        self.logger.error(message)
    
    def success(self, message: str):
        """Log success message (as info with prefix)"""
        self.logger.info(f"✓ {message}")
    
    def progress(self, current: int, total: int, message: str = ""):
        """Log progress message"""
        if message:
            self.logger.info(f"[{current}/{total}] {message}")
        else:
            self.logger.info(f"Progress: {current}/{total}")
    
    # Legacy compatibility methods
    def debug_log(self, message: str, level: str = "INFO"):
        """Legacy compatibility for debug_log function"""
        level_map = {
            "INFO": self.info,
            "DEBUG": self.debug,
            "WARNING": self.warning,
            "ERROR": self.error,
            "WARN": self.warning
        }
        log_func = level_map.get(level.upper(), self.info)
        log_func(message)

# Example usage functions for easy migration
def create_logger(script_name: str, quiet: bool = False) -> LoggerAdapter:
    """
    Create a logger adapter for easy migration from print statements.
    
    Args:
        script_name: Name of the script
        quiet: If True, suppress verbose console output
    
    Returns:
        LoggerAdapter: Easy-to-use logger adapter
    """
    setup_logging(script_name, quiet=quiet)
    return LoggerAdapter(script_name)