// Password, one-time code and recovery code fields accept only text typed by hand:
// no paste, no drop, no browser / password-manager autofill. Anything that changes the field
// without a real typing event empties it again. (Switch off with SECUREDESK_BLOCK_PASTE=false on the server.)
// Note: this is a browser-side aid. It cannot stop a script that posts to the server directly;
// the real protection stays the lockout and the second factor.
(function () {
    var meta = document.querySelector('meta[name="sd-block-paste"]');
    if (meta && meta.content === 'false') return;

    var SELECTOR = [
        'input[type="password"]',
        'input[name="Input.TwoFactorCode"]',
        'input[name="Input.RecoveryCode"]',
        'input[name="Input.Code"]',
        'input[autocomplete="one-time-code"]'
    ].join(',');

    function typedKind(t) {
        // inputType values that come from a keyboard (or an on-screen keyboard / IME)
        return t === 'insertText' || t === 'insertLineBreak' || t === 'insertCompositionText' ||
            t === 'insertFromComposition' || t === 'deleteCompositionText' ||
            (t && t.indexOf('delete') === 0) || t === 'historyUndo' || t === 'historyRedo';
    }

    function note(el, text) {
        var n = el.__sdNote;
        if (!n) {
            n = document.createElement('div');
            n.setAttribute('role', 'status');
            n.style.cssText = 'font-size:12px;margin-top:4px;color:#ffb4a9;min-height:0;';
            el.parentNode.insertBefore(n, el.nextSibling);
            el.__sdNote = n;
        }
        n.textContent = text;
        clearTimeout(el.__sdNoteTimer);
        el.__sdNoteTimer = setTimeout(function () { n.textContent = ''; }, 4000);
    }

    function guard(el) {
        if (el.__sdGuard) return;
        el.__sdGuard = true;
        var typed = el.value || '';
        el.setAttribute('autocomplete', el.type === 'password' ? 'off' : 'off');
        el.setAttribute('autocapitalize', 'none');
        el.setAttribute('spellcheck', 'false');

        function clear(reason) {
            el.value = '';
            typed = '';
            note(el, reason || 'Please type this by hand. Pasting and autofill are turned off.');
        }

        ['paste', 'drop', 'dragenter'].forEach(function (ev) {
            el.addEventListener(ev, function (e) {
                e.preventDefault();
                if (ev !== 'dragenter') note(el, 'Please type this by hand. Pasting is turned off.');
            });
        });
        el.addEventListener('beforeinput', function (e) {
            if (e.inputType && !typedKind(e.inputType)) {
                e.preventDefault();
                note(el, 'Please type this by hand. Pasting is turned off.');
            }
        });
        el.addEventListener('input', function (e) {
            if (!e.inputType || !typedKind(e.inputType)) {
                clear();            // autofill or a script changed the value
            } else {
                typed = el.value;
            }
        });
        // autofill that fires no input event: check again at the usual moments
        function verify() {
            if (el.value !== typed) clear();
        }
        el.addEventListener('change', verify);
        el.addEventListener('blur', verify);
        el.addEventListener('animationstart', verify);   // Chrome autofill shows :-webkit-autofill
        window.addEventListener('pageshow', verify);
        setTimeout(verify, 300);
        setTimeout(verify, 1200);

        if (el.form && !el.form.__sdGuardSubmit) {
            el.form.__sdGuardSubmit = true;
            el.form.addEventListener('submit', function (e) {
                var bad = false;
                el.form.querySelectorAll(SELECTOR).forEach(function (f) {
                    if (f.__sdGuard && f.__sdTyped && f.value !== f.__sdTyped()) {
                        bad = true;
                        f.value = '';
                    }
                });
                if (bad) {
                    e.preventDefault();
                    e.stopImmediatePropagation();
                }
            }, true);
        }
        el.__sdTyped = function () { return typed; };
    }

    function scan() {
        document.querySelectorAll(SELECTOR).forEach(guard);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan); else scan();
    new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
})();
