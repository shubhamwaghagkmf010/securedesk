// SecureDesk: colour themes (per browser) and, for server admins, a custom page background image.
(function () {
    var THEMES = [
        ["aurora", "Aurora", "linear-gradient(135deg,#2DD4BF,#7C6CFF)"],
        ["ocean", "Ocean", "linear-gradient(135deg,#38BDF8,#6366F1)"],
        ["sunset", "Sunset", "linear-gradient(135deg,#FB923C,#F472B6)"],
        ["emerald", "Emerald", "linear-gradient(135deg,#34D399,#A3E635)"],
        ["rose", "Rose", "linear-gradient(135deg,#FB7185,#C084FC)"],
        ["graphite", "Graphite", "linear-gradient(135deg,#94A3B8,#64748B)"]
    ];
    var KEY = "sd-theme";

    function stored() { try { return localStorage.getItem(KEY) || "aurora"; } catch (e) { return "aurora"; } }
    function apply(name) {
        if (name === "aurora") { document.documentElement.removeAttribute("data-sd-theme"); }
        else { document.documentElement.setAttribute("data-sd-theme", name); }
    }
    apply(stored());

    function buildPalette() {
        // only on pages with the side menu (dashboard); not on the remote screen or login
        if (!document.querySelector(".sidebar") || document.getElementById("sdPalette")) { return; }

        var box = document.createElement("div");
        box.id = "sdPalette";
        var html = "<button type=\"button\" class=\"sd-pal-btn\" title=\"Themes\" aria-label=\"Themes\">" +
            "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" +
            "<path d=\"M12 3a9 9 0 1 0 0 18c1.1 0 1.8-.9 1.5-1.9-.3-1 .3-2.1 1.4-2.1H17a4 4 0 0 0 4-4c0-5-4-10-9-10z\"/>" +
            "<circle cx=\"7.5\" cy=\"11\" r=\"1\"/><circle cx=\"10.5\" cy=\"7\" r=\"1\"/><circle cx=\"15\" cy=\"7.5\" r=\"1\"/></svg></button>" +
            "<div class=\"sd-pal-panel\"><h6>Colour theme</h6><div class=\"sd-swatches\">";
        THEMES.forEach(function (t) {
            html += "<button type=\"button\" class=\"sd-sw\" data-theme=\"" + t[0] + "\" style=\"background:" + t[2] + "\">" + t[1] + "</button>";
        });
        html += "</div>";
        if (window.SD_ADMIN === true) {
            html += "<h6>Page background (admin)</h6>" +
                "<button type=\"button\" class=\"sd-pal-action primary\" id=\"sdUpload\">Upload image…</button>" +
                "<button type=\"button\" class=\"sd-pal-action\" id=\"sdReset\">Reset to default</button>" +
                "<input type=\"file\" id=\"sdFile\" accept=\"image/png,image/jpeg,image/webp\" hidden />" +
                "<div class=\"sd-pal-note\" id=\"sdNote\">PNG, JPG or WEBP, up to 6 MB.</div>";
        }
        html += "</div>";
        box.innerHTML = html;
        document.body.appendChild(box);

        function mark() {
            var cur = stored();
            box.querySelectorAll(".sd-sw").forEach(function (b) { b.classList.toggle("active", b.getAttribute("data-theme") === cur); });
        }
        mark();

        box.querySelector(".sd-pal-btn").addEventListener("click", function () { box.classList.toggle("open"); });
        document.addEventListener("click", function (ev) { if (!box.contains(ev.target)) { box.classList.remove("open"); } });
        box.querySelectorAll(".sd-sw").forEach(function (b) {
            b.addEventListener("click", function () {
                var name = b.getAttribute("data-theme");
                try { localStorage.setItem(KEY, name); } catch (e) { }
                apply(name);
                mark();
            });
        });

        var file = box.querySelector("#sdFile");
        if (!file) { return; }
        var note = box.querySelector("#sdNote");
        function say(t) { note.textContent = t; }
        function send(method, body) {
            return fetch("/branding/background", { method: method, body: body, headers: { "X-SD-Upload": "1" }, credentials: "same-origin" })
                .then(function (r) {
                    if (r.ok) { location.reload(); return; }
                    return r.text().then(function (t) { say(t && t.length < 120 ? t : "Not allowed (server administrators only)."); });
                })
                .catch(function () { say("Upload failed."); });
        }
        box.querySelector("#sdUpload").addEventListener("click", function () { file.click(); });
        file.addEventListener("change", function () {
            if (!file.files.length) { return; }
            if (file.files[0].size > 6 * 1024 * 1024) { say("Image is larger than 6 MB."); return; }
            var fd = new FormData();
            fd.append("file", file.files[0]);
            say("Uploading…");
            send("POST", fd);
        });
        box.querySelector("#sdReset").addEventListener("click", function () { send("DELETE"); });
    }

    document.addEventListener("DOMContentLoaded", buildPalette);
    window.addEventListener("load", function () { setTimeout(buildPalette, 600); });
})();
