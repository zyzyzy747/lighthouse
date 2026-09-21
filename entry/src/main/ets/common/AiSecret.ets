/**
 * 灯塔 Lighthouse · 内置演示密钥
 * ------------------------------------------------------------------
 * ⚠ 本文件由 tools/inject_key.py 生成/覆盖，**不要手工提交真实密钥**。
 *   - 写入：python inject_key.py            （读 secrets/deepseek.key）
 *   - 抹除：python inject_key.py --strip    （交稿前跑，key 变回空串）
 *
 * 为什么单独拆一个文件：密钥是唯一需要"能随时抹掉"的东西。
 * 把它从 AiTypes.ets 里剥出来，交稿前只动这一个文件，
 * 就不会顺手改坏别的常量（端点、超时、模型名）。
 *
 * ⚠ 安全底线：hap 包内字节码可被反编译，硬编码密钥**一定会泄露**。
 *   所以这里只放一个"单独申请、只充少量余额、设了消费限额"的演示 key，
 *   绝不能放主账号 key。正式口径是 BYOK（用户自带密钥），见设置页。
 */
export const BUILTIN_DEMO_KEY: string = '';
