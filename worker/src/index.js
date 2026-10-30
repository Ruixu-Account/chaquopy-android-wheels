export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // 1. 处理 .whl 文件的下载代理
    if (path.endsWith(".whl")) {
      const filename = path.slice(1); // 去掉开头的 /
      
      // 安全校验
      if (filename.includes("/") || filename.includes("..")) {
        return new Response("Invalid path", { status: 400 });
      }

      const githubUrl = `https://github.com/Ruixu-Account/chaquopy-android-wheels/releases/download/latest/${filename}`;
      
      const resp = await fetch(githubUrl, {
        method: request.method,
        redirect: "follow",
        headers: { "User-Agent": request.headers.get("User-Agent") || "wheel-proxy" },
      });

      if (resp.status === 404) {
        return new Response("File not found: " + filename + "\n", { status: 404 });
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
    }

    // 2. 解决 PEP 503 痛点：如果访问 /simple 或 /simple/numpy 没带末尾斜杠，自动 308 重定向补全
    // 否则 env.ASSETS 可能会找不到目录下的 index.html
    if (path.startsWith("/simple") && !path.endsWith("/")) {
      url.pathname = path + "/";
      return Response.redirect(url.toString(), 308);
    }

    // 3. 其他所有请求（比如 /simple/ 或 /simple/numpy/）全部扔给静态资源处理！
    // Cloudflare 底层会自动去 public 目录里找对应的 index.html 返回
    return env.ASSETS.fetch(request);
  },
};
