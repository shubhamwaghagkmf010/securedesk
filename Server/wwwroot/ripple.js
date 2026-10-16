// SecureDesk: water-drop ripple on every click of a button, tab or menu link.
(function () {
    var SELECTOR = "button, .btn, .nav-link, .nav-item a, a.nav-link, [role=tab], .option-button, .horizontal-bar-button, .page-link, .list-group-item-action";

    document.addEventListener("pointerdown", function (ev) {
        if (ev.button !== undefined && ev.button !== 0) { return; }
        var target = ev.target && ev.target.closest ? ev.target.closest(SELECTOR) : null;
        if (!target || target.disabled || target.hasAttribute("disabled")) { return; }

        var rect = target.getBoundingClientRect();
        var size = Math.max(rect.width, rect.height) * 2.2;
        var x = ev.clientX - rect.left;
        var y = ev.clientY - rect.top;

        var cs = getComputedStyle(target);
        if (cs.position === "static") { target.style.position = "relative"; }
        if (cs.overflow === "visible") { target.style.overflow = "hidden"; }

        var wrap = document.createElement("span");
        wrap.className = "sd-ripple";
        wrap.style.left = x + "px";
        wrap.style.top = y + "px";
        wrap.style.setProperty("--sd-ripple-size", size + "px");
        wrap.innerHTML = "<i class=\"sd-drop\"></i><i class=\"sd-ring\"></i><i class=\"sd-ring sd-ring2\"></i>";
        target.appendChild(wrap);
        setTimeout(function () { wrap.remove(); }, 1000);
    }, true);
})();
