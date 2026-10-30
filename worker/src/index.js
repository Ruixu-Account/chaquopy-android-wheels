export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // 1. 处理 .whl 文件的下载代理
    if (path.endsWith(".whl")) {
      const filename = path.slice(1);
      
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

      return new Response(resp.body, { status: resp.status, headers });
    }

    // 2. 补全 /simple 结尾的斜杠，防止 ASSETS 解析失败
    if (path.startsWith("/simple") && !path.endsWith("/")) {
      url.pathname = path + "/";
      return Response.redirect(url.toString(), 308);
    }

    // 3. 其他请求交给静态资源处理
    return env.ASSETS.fetch(request);
  },
};
