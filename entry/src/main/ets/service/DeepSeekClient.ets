/**
 * 灯塔 Lighthouse · DeepSeek 客户端
 * 目标路径：entry/src/main/ets/service/DeepSeekClient.ets
 * ------------------------------------------------------------------
 * 职责边界（刻意收窄）：
 *   把「一组消息」变成「一段模型输出」，不做任何业务判断。
 *
 * 四条设计规则：
 *   ① 任何失败都必须带可判定的 errorKind —— 上层据此决定是否降级到本地引擎
 *   ② 结构化任务一律强制 JSON Output，并把 ```json 包裹剥掉再解析
 *   ③ 密钥只从偏好库读，代码里不出现明文 key（内置演示密钥由 AiSecret 提供）
 *   ④ 一切请求都受 SOFT_DEADLINE 约束 —— 演示时让评委干等 60 秒是不可接受的，
 *      超时立刻返回 TIMEOUT，由上层无缝切到本地引擎，用户几乎无感
 *
 * ⚠ 两个已验证的接口事实（来自官方文档，别凭记忆改）：
 *   - 模型名是 `deepseek-flash`，旧的 `deepseek-chat` 别名已退役
 *   - OpenAI 兼容接口**没有** {type:'text'} 这种 response_format，非 JSON 场景必须整个省略该字段
 */

import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';
import {
  AiConfig, AiErrorKind, AiResult,
  ChatMessage, ChatRequest, ChatResponse, ChatChoice, UsageInfo
} from '../common/AiTypes';

export class DeepSeekClient {
  private static instance: DeepSeekClient | null = null;

  private apiKey: string = '';
  private allowCloud: boolean = true;

  /** 最近一次调用的耗时，供 UI 展示「本次分析用时 x.x 秒」 */
  lastLatencyMs: number = 0;
  /** 最近一次调用的 token 消耗，供答辩时讲成本 */
  lastUsage: UsageInfo | undefined = undefined;

  /** 单例入口 */
  static get(): DeepSeekClient {
    if (DeepSeekClient.instance === null) {
      DeepSeekClient.instance = new DeepSeekClient();
    }
    return DeepSeekClient.instance;
  }

  /* ---------------- 密钥与开关 ---------------- */

  setApiKey(key: string): void {
    this.apiKey = key.trim();
  }

  setAllowCloud(allow: boolean): void {
    this.allowCloud = allow;
  }

  hasKey(): boolean {
    return this.apiKey.length > 0;
  }

  isCloudEnabled(): boolean {
    return this.allowCloud && this.apiKey.length > 0;
  }

  isCloudAllowed(): boolean {
    return this.allowCloud;
  }

  /** 密钥尾部四位，用于设置页回显（绝不回显完整 key） */
  keyTail(): string {
    if (this.apiKey.length < 8) {
      return '';
    }
    return this.apiKey.substring(this.apiKey.length - 4);
  }

  /** 启动时加载偏好；用户没填则回落到构建期注入的演示密钥 */
  async load(ctx: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, AiConfig.STORE_NAME);
      const rawKey: preferences.ValueType = await store.get(AiConfig.PREF_API_KEY, '');
      const rawAllow: preferences.ValueType = await store.get(AiConfig.PREF_ALLOW_CLOUD, true);
      if (typeof rawKey === 'string' && rawKey.length > 0) {
        this.apiKey = rawKey;
        Log.i('AI key 来源：用户偏好设置');
      } else {
        this.apiKey = AiConfig.DEMO_KEY;
        Log.i(this.apiKey.length > 0 ? 'AI key 来源：内置演示密钥' : 'AI key 缺失，将走本地引擎');
      }
      this.allowCloud = typeof rawAllow === 'boolean' ? rawAllow : true;
    } catch (e) {
      this.apiKey = AiConfig.DEMO_KEY;
      this.allowCloud = true;
      Log.w('读取 AI 偏好失败，使用内置默认值');
    }
  }

  /** 设置页保存密钥 */
  async saveKey(ctx: common.Context, key: string): Promise<void> {
    this.setApiKey(key);
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, AiConfig.STORE_NAME);
      await store.put(AiConfig.PREF_API_KEY, this.apiKey);
      await store.flush();
    } catch (e) {
      // 存失败不影响本次会话使用，静默即可
    }
  }

  async saveAllowCloud(ctx: common.Context, allow: boolean): Promise<void> {
    this.setAllowCloud(allow);
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, AiConfig.STORE_NAME);
      await store.put(AiConfig.PREF_ALLOW_CLOUD, allow);
      await store.flush();
    } catch (e) {
    }
  }

  /* ---------------- 主入口 ---------------- */

  /** 取回纯文本（适合需要自由发挥的场景，如扮演面试官追问） */
  async chatRaw(messages: ChatMessage[],
                maxTokens: number = AiConfig.DEFAULT_MAX_TOKENS,
                temperature: number = 0.7,
                model: string = AiConfig.MODEL_FAST): Promise<AiResult<string>> {
    return this.chat(messages, maxTokens, false, temperature, model);
  }

  /**
   * 取回结构化对象（复盘打分、JD 解析走这条）。
   * 强制 JSON Output + 低温度，保证同一份输入得到稳定可比的分数。
   *
   * ⚠ thinking 模式会忽略 temperature，所以这里必须同时关掉 thinking，
   *   否则「低温度保证打分稳定」这条设计前提就不成立了。
   */
  async chatJson<T>(messages: ChatMessage[],
                    maxTokens: number = AiConfig.DEFAULT_MAX_TOKENS,
                    model: string = AiConfig.MODEL_FAST): Promise<AiResult<T>> {
    const textResult: AiResult<string> = await this.chat(messages, maxTokens, true, 0.2, model);
    this.lastLatencyMs = textResult.latencyMs !== undefined ? textResult.latencyMs : 0;
    this.lastUsage = textResult.usage;

    if (!textResult.ok) {
      const failed: AiResult<T> = {
        ok: false,
        errorKind: textResult.errorKind,
        error: textResult.error,
        raw: textResult.raw,
        latencyMs: textResult.latencyMs
      };
      return failed;
    }
    const cleaned: string = DeepSeekClient.stripFence(textResult.raw !== undefined ? textResult.raw : '');
    try {
      const parsed: T = JSON.parse(cleaned) as T;
      const ok: AiResult<T> = {
        ok: true,
        errorKind: AiErrorKind.NONE,
        data: parsed,
        raw: cleaned,
        latencyMs: textResult.latencyMs,
        usage: textResult.usage
      };
      return ok;
    } catch (e) {
      const bad: AiResult<T> = {
        ok: false,
        errorKind: AiErrorKind.PARSE,
        error: 'AI 返回内容不是合法 JSON',
        raw: cleaned,
        latencyMs: textResult.latencyMs
      };
      return bad;
    }
  }

  /* ---------------- 内部实现 ---------------- */

  private async chat(messages: ChatMessage[], maxTokens: number, jsonMode: boolean,
                     temperature: number, model: string): Promise<AiResult<string>> {
    const started: number = Date.now();

    if (!this.allowCloud) {
      return this.fail(AiErrorKind.OFFLINE, '云端 AI 已关闭，使用本地引擎', started);
    }
    if (this.apiKey.length === 0) {
      return this.fail(AiErrorKind.NO_KEY, '未配置 DeepSeek API Key', started);
    }

    let lastKind: AiErrorKind = AiErrorKind.UNKNOWN;
    let lastMsg: string = '未知错误';
    let lastRaw: string = '';

    for (let attempt: number = 0; attempt <= AiConfig.MAX_RETRY; attempt++) {
      if (attempt > 0) {
        // 没预算就别重试了 —— 重试的意义是救回可恢复的失败，
        // 而不是把用户的时间耗光在等待上。
        if (Date.now() - started > AiConfig.SOFT_DEADLINE) {
          lastKind = AiErrorKind.TIMEOUT;
          lastMsg = '云端响应过慢，已切到本地引擎';
          break;
        }
        await DeepSeekClient.sleep(800 * attempt);
      }
      const r: AiResult<string> = await this.once(messages, maxTokens, jsonMode, temperature, model, started);
      if (r.ok) {
        return r;
      }
      lastKind = r.errorKind;
      lastMsg = r.error !== undefined ? r.error : '';
      lastRaw = r.raw !== undefined ? r.raw : '';
      // 只有这三类值得重试；offline / auth / no_key / timeout 重试毫无意义
      const retriable: boolean = lastKind === AiErrorKind.SERVER
        || lastKind === AiErrorKind.RATE_LIMIT
        || lastKind === AiErrorKind.PARSE;
      if (!retriable) {
        break;
      }
    }

    const final: AiResult<string> = {
      ok: false, errorKind: lastKind, error: lastMsg, raw: lastRaw,
      latencyMs: Date.now() - started
    };
    return final;
  }

  /** 单次带熔断的请求 —— 唯一与网络打交道的地方 */
  private async once(messages: ChatMessage[], maxTokens: number, jsonMode: boolean,
                     temperature: number, model: string, started: number): Promise<AiResult<string>> {
    const request: http.HttpRequest = http.createHttp();

    const remain: number = AiConfig.SOFT_DEADLINE - (Date.now() - started);
    if (remain <= 0) {
      request.destroy();
      return this.fail(AiErrorKind.TIMEOUT, '云端响应过慢，已切到本地引擎', started);
    }

    // 非 JSON 场景**不能**传 {type:'text'} —— 该值不存在，会被拒。
    // 正确做法是让字段整体缺席（JSON.stringify 会忽略 undefined 字段）。
    const body: ChatRequest = {
      model: model,
      messages: messages,
      stream: false,
      temperature: temperature,
      max_tokens: maxTokens,
      // 关掉思维链：结构化任务要的是稳定可比的输出，不是更长的思考。
      thinking: { type: 'disabled' }
    };
    if (jsonMode) {
      body.response_format = { type: 'json_object' };
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + this.apiKey
    };

    const send: Promise<AiResult<string>> =
      this.send(request, body, headers, started);

    // 熔断器：谁先到就用谁的结果。超时分支同时断掉底层请求，不再白等。
    const fuse: Promise<AiResult<string>> = new Promise<AiResult<string>>(
      (resolve: (r: AiResult<string>) => void) => {
        setTimeout(() => {
          try {
            request.destroy();
          } catch (e) {
          }
          resolve(this.fail(AiErrorKind.TIMEOUT,
            '云端响应超过 ' + Math.round(remain / 1000) + ' 秒，已切到本地引擎', started));
        }, remain);
      }
    );

    let raced: AiResult<string>;
    try {
      raced = await Promise.race<AiResult<string>>([send, fuse]);
    } catch (e) {
      raced = this.fail(AiErrorKind.UNKNOWN, '请求异常', started);
    } finally {
      try {
        request.destroy();
      } catch (e) {
      }
    }
    return raced;
  }

  /** 真正的 HTTP 收发。所有异常都被吃掉并转成 AiResult，保证不 reject。 */
  private async send(request: http.HttpRequest, body: ChatRequest,
                     headers: Record<string, string>, started: number): Promise<AiResult<string>> {
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: AiConfig.CONNECT_TIMEOUT,
        readTimeout: AiConfig.READ_TIMEOUT
      };
      const resp: http.HttpResponse = await request.request(AiConfig.ENDPOINT, options);
      const code: number = resp.responseCode;
      const text: string = typeof resp.result === 'string' ? resp.result : '';

      if (code === 200) {
        try {
          const parsed: ChatResponse = JSON.parse(text) as ChatResponse;
          const choices: ChatChoice[] = parsed.choices;
          if (choices !== undefined && choices.length > 0) {
            Log.i(`AI 调用成功 ${Date.now() - started}ms tokens=${parsed.usage !== undefined ? parsed.usage.total_tokens : '?'}`);
            const ok: AiResult<string> = {
              ok: true,
              errorKind: AiErrorKind.NONE,
              raw: choices[0].message.content,
              latencyMs: Date.now() - started,
              usage: parsed.usage
            };
            return ok;
          }
          return this.failRaw(AiErrorKind.SERVER, '响应中没有 choices', text, started);
        } catch (e) {
          return this.failRaw(AiErrorKind.PARSE, '响应体不是合法 JSON', text, started);
        }
      }

      if (code === 401 || code === 403) {
        Log.e('AI 鉴权失败 HTTP ' + code);
        return this.failRaw(AiErrorKind.AUTH, 'API Key 无效或无权限（HTTP ' + code + '）', text, started);
      }
      if (code === 429) {
        return this.failRaw(AiErrorKind.RATE_LIMIT, '请求过于频繁（HTTP 429）', text, started);
      }
      if (code >= 500) {
        return this.failRaw(AiErrorKind.SERVER, '服务端错误（HTTP ' + code + '）', text, started);
      }
      return this.failRaw(AiErrorKind.UNKNOWN, '请求失败（HTTP ' + code + '）', text, started);
    } catch (e) {
      // 抛异常 = 连不上：DNS 失败、超时、无网。
      // 这正是「车间/地铁断网」场景，上层据此降级到本地引擎。
      const msg: string = e !== undefined && e !== null ? JSON.stringify(e) : '网络不可达';
      Log.w('AI 网络异常：' + msg);
      return this.fail(AiErrorKind.OFFLINE, msg, started);
    }
  }

  /* ---------------- 小工具 ---------------- */

  /** 剥掉模型可能加上的 ```json ... ``` 包裹 —— 最常见的解析崩因 */
  private static stripFence(text: string): string {
    let s: string = text.trim();
    if (s.startsWith('```')) {
      const firstBreak: number = s.indexOf('\n');
      if (firstBreak >= 0) {
        s = s.substring(firstBreak + 1);
      }
      const lastFence: number = s.lastIndexOf('```');
      if (lastFence >= 0) {
        s = s.substring(0, lastFence);
      }
      s = s.trim();
    }
    // 兜底：截取第一个 { 到最后一个 } 之间的内容
    const firstBrace: number = s.indexOf('{');
    const lastBrace: number = s.lastIndexOf('}');
    if (firstBrace > 0 && lastBrace > firstBrace) {
      s = s.substring(firstBrace, lastBrace + 1);
    }
    return s;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private fail(kind: AiErrorKind, msg: string, started: number): AiResult<string> {
    const r: AiResult<string> = { ok: false, errorKind: kind, error: msg, latencyMs: Date.now() - started };
    return r;
  }

  private failRaw(kind: AiErrorKind, msg: string, raw: string, started: number): AiResult<string> {
    const r: AiResult<string> = {
      ok: false, errorKind: kind, error: msg, raw: raw, latencyMs: Date.now() - started
    };
    return r;
  }
}
