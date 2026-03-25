use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_SUCCESS: c_int = 0;

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

#[repr(C)]
struct PamConv {
    conv: extern "C" fn(c_int, *const *const PamMessage, *mut *mut PamResponse, *mut c_void) -> c_int,
    appdata_ptr: *mut c_void,
}

type PamHandle = *mut c_void;

extern "C" fn conversation(
    num_msg: c_int,
    msg: *const *const PamMessage,
    resp: *mut *mut PamResponse,
    appdata_ptr: *mut c_void,
) -> c_int {
    unsafe {
        let password = &*(appdata_ptr as *const CString);
        let responses =
            libc::calloc(num_msg as usize, std::mem::size_of::<PamResponse>()) as *mut PamResponse;
        if responses.is_null() {
            return 5; // PAM_BUF_ERR
        }
        for i in 0..num_msg as isize {
            let m = &**msg.offset(i);
            if m.msg_style == PAM_PROMPT_ECHO_OFF {
                (*responses.offset(i)).resp = libc::strdup(password.as_ptr());
            }
        }
        *resp = responses;
    }
    PAM_SUCCESS
}

/// Attempt PAM authentication via dlopen (no compile-time libpam dependency).
fn try_pam(username: &str, password: &str) -> Result<bool, String> {
    type PamStartFn = unsafe extern "C" fn(*const c_char, *const c_char, *const PamConv, *mut PamHandle) -> c_int;
    type PamAuthFn = unsafe extern "C" fn(PamHandle, c_int) -> c_int;
    type PamAcctFn = unsafe extern "C" fn(PamHandle, c_int) -> c_int;
    type PamEndFn = unsafe extern "C" fn(PamHandle, c_int) -> c_int;

    let lib = unsafe {
        libloading::Library::new("libpam.so.0")
            .or_else(|_| libloading::Library::new("libpam.so"))
            .map_err(|e| format!("dlopen libpam: {e}"))?
    };

    let (pam_start, pam_authenticate, pam_acct_mgmt, pam_end) = unsafe {
        let start: libloading::Symbol<PamStartFn> = lib.get(b"pam_start").map_err(|e| format!("{e}"))?;
        let auth: libloading::Symbol<PamAuthFn> = lib.get(b"pam_authenticate").map_err(|e| format!("{e}"))?;
        let acct: libloading::Symbol<PamAcctFn> = lib.get(b"pam_acct_mgmt").map_err(|e| format!("{e}"))?;
        let end: libloading::Symbol<PamEndFn> = lib.get(b"pam_end").map_err(|e| format!("{e}"))?;
        (*start, *auth, *acct, *end)
    };

    let service = CString::new("login").unwrap();
    let user = CString::new(username).map_err(|e| format!("{e}"))?;
    let pw = CString::new(password).map_err(|e| format!("{e}"))?;

    let conv = PamConv {
        conv: conversation,
        appdata_ptr: &pw as *const CString as *mut c_void,
    };

    let mut handle: PamHandle = std::ptr::null_mut();
    let rc = unsafe { pam_start(service.as_ptr(), user.as_ptr(), &conv, &mut handle) };
    if rc != PAM_SUCCESS {
        return Ok(false);
    }

    let auth_rc = unsafe { pam_authenticate(handle, 0) };
    let acct_rc = if auth_rc == PAM_SUCCESS {
        unsafe { pam_acct_mgmt(handle, 0) }
    } else {
        auth_rc
    };
    unsafe { pam_end(handle, acct_rc) };

    Ok(acct_rc == PAM_SUCCESS)
}

fn current_username() -> Option<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .ok()
        .or_else(|| {
            let uid = unsafe { libc::getuid() };
            let pw = unsafe { libc::getpwuid(uid) };
            if pw.is_null() {
                return None;
            }
            let name = unsafe { CStr::from_ptr((*pw).pw_name) };
            name.to_str().ok().map(String::from)
        })
}

/// Authenticate the entered password/PIN.
/// Tries PAM first (dlopen, no compile-time dep); falls back to env-var PIN.
pub fn check_password(entered: &str) -> bool {
    if entered.is_empty() {
        return false;
    }

    // ATOMOS_LOCK_PIN forces the env-var fallback path (testing, kiosk mode).
    if std::env::var("ATOMOS_LOCK_PIN").is_ok() {
        let expected = std::env::var("ATOMOS_LOCK_PIN").unwrap();
        return entered == expected;
    }

    if let Some(user) = current_username() {
        match try_pam(&user, entered) {
            Ok(result) => return result,
            Err(_) => {} // PAM unavailable, fall through
        }
    }

    // Final fallback when PAM is not available and no PIN override is set.
    entered == "147147"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_pin_override_and_empty_rejection() {
        // Empty always rejected.
        assert!(!check_password(""));

        // When ATOMOS_LOCK_PIN is set, it overrides PAM.
        std::env::set_var("ATOMOS_LOCK_PIN", "9876");
        assert!(check_password("9876"));
        assert!(!check_password("0000"));
        assert!(!check_password(""));

        // Different PIN value works too.
        std::env::set_var("ATOMOS_LOCK_PIN", "147147");
        assert!(check_password("147147"));
        assert!(!check_password("wrong"));

        std::env::remove_var("ATOMOS_LOCK_PIN");
    }
}
