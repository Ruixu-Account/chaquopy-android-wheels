export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname.slice(1);

    if (!path) {
      return new Response("Wheel downloads. Usage: /<filename>.whl\n", {
        headers: { "Content-Type": "text/plain; charset=utf-8" }
      });
    }

    if (!path.endsWith(".whl") || path.includes("/") || path.includes("..")) {
      return new Response("Only .whl files allowed\n", { status: 400 });
    }

    const githubUrl = `https://github.com/Ruixu-Account/chaquopy-android-wheels/releases/download/latest/${path}`;

    const resp = await fetch(githubUrl, {
      method: request.method,
      redirect: "follow",
      headers: { "User-Agent": request.headers.get("User-Agent") || "wheel-proxy" },
    });

    if (resp.status === 404) {
      return new Response("File not found: " + path + "\n", { status: 404 });
    }

    const headers = new Headers();
    headers.set("Content-Type", "application/octet-stream");
    const len = resp.headers.get("Content-Length");
    if (len) headers.set("Content-Length", len);
    headers.set("Cache-Control", "public, max-age=86400, immutable");
    headers.set("Access-Control-Allow-Origin", "*");
    headers.set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");

    return new Response(resp.body, {
      status: resp.status,
      headers,
    });
  },
};
