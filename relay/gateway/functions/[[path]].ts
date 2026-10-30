// 所有路径原样转发给 daily-relay（服务绑定，走 Cloudflare 内部，不经过公网）。
// 鉴权、短信解析等全部由 daily-relay 负责，这里不做任何处理。
interface Env {
  RELAY: { fetch(request: Request): Promise<Response> };
}

export const onRequest = (context: { request: Request; env: Env }) => context.env.RELAY.fetch(context.request);
