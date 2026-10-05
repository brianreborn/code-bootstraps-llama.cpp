"""Lock this process in RAM so the kernel swaps a big model before this process.

Linux: mlockall. Windows: lock the working set (SeLockMemoryPrivilege).
A failure is a warning. The process keeps running. scripts/raise.sh and
scripts/raise.ps1 are how a mortal user is granted the right.
"""
import ctypes
import sys


def try_lock_process(name):
    """Return True if the lock was taken. Print one warning if this OS can lock but did not."""
    if sys.platform.startswith("linux"):
        return _lock_linux(name)
    if sys.platform == "win32":
        return _lock_windows(name)
    return False


def _lock_linux(name):
    import resource
    libc = ctypes.CDLL(None, use_errno=True)
    MCL_CURRENT = 1
    MCL_FUTURE = 2
    if libc.mlockall(MCL_CURRENT | MCL_FUTURE) == 0:
        return True
    err = ctypes.get_errno()
    soft, hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    why = "errno %d" % err
    if soft not in (resource.RLIM_INFINITY, -1) and soft < 64 * 1024 * 1024:
        why = "memlock limit is %s bytes" % soft
    sys.stderr.write(
        "%s: could not mlock this process (%s). Run scripts/raise.sh, then sign in again.\n" % (name, why))
    return False


def _lock_windows(name):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    adv = ctypes.WinDLL("advapi32", use_last_error=True)
    SE_PRIVILEGE_ENABLED = 0x00000002
    TOKEN_ADJUST_PRIVILEGES = 0x0020
    TOKEN_QUERY = 0x0008
    QUOTA_LIMITS_HARDWS_MIN_ENABLE = 0x00000001

    class LUID(ctypes.Structure):
        _fields_ = [("LowPart", ctypes.c_uint32), ("HighPart", ctypes.c_int32)]

    class LUID_AND_ATTRIBUTES(ctypes.Structure):
        _fields_ = [("Luid", LUID), ("Attributes", ctypes.c_uint32)]

    class TOKEN_PRIVILEGES(ctypes.Structure):
        _fields_ = [("PrivilegeCount", ctypes.c_uint32), ("Privileges", LUID_AND_ATTRIBUTES * 1)]

    token = ctypes.c_void_p()
    if not adv.OpenProcessToken(kernel.GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ctypes.byref(token)):
        sys.stderr.write("%s: could not open the process token. Run scripts\\raise.ps1, then sign in again.\n" % name)
        return False
    luid = LUID()
    if not adv.LookupPrivilegeValueW(None, "SeLockMemoryPrivilege", ctypes.byref(luid)):
        sys.stderr.write("%s: SeLockMemoryPrivilege is not present. Run scripts\\raise.ps1, then sign in again.\n" % name)
        return False
    tp = TOKEN_PRIVILEGES()
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED
    if not adv.AdjustTokenPrivileges(token, False, ctypes.byref(tp), 0, None, None):
        sys.stderr.write("%s: could not enable SeLockMemoryPrivilege. Run scripts\\raise.ps1, then sign in again.\n" % name)
        return False
    if ctypes.get_last_error() == 1300:  # ERROR_NOT_ALL_ASSIGNED
        sys.stderr.write("%s: this account cannot lock memory yet. Run scripts\\raise.ps1, then sign in again.\n" % name)
        return False
    min_size = ctypes.c_size_t(64 * 1024 * 1024)
    max_size = ctypes.c_size_t(256 * 1024 * 1024)
    ok = kernel.SetProcessWorkingSetSizeEx(kernel.GetCurrentProcess(), min_size, max_size, QUOTA_LIMITS_HARDWS_MIN_ENABLE)
    if not ok:
        sys.stderr.write("%s: could not lock the working set (error %d). Run scripts\\raise.ps1, then sign in again.\n"
                         % (name, ctypes.get_last_error()))
        return False
    return True
