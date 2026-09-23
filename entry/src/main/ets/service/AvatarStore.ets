import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { KvRepo } from '../repository/KvRepo';
import { Log } from '../common/Logger';

/** KV 里存头像沙箱路径的键。缺失 / 空 ⇒ 用内置默认头像。 */
const KEY_AVATAR: string = 'profile_avatar';

/**
 * 内置默认头像（rawfile，随包走，不落盘）。
 * ⚠ 调用处必须写字面量：`$rawfile('avatar_default.png')` 是编译期宏，
 *   传这个常量变量编译不过 —— 它只用于文案与自检时的读取。
 */
export const DEFAULT_AVATAR_RAW: string = 'avatar_default.png';

/**
 * 头像存取。
 *
 * 三条规矩，都是踩出来的：
 *
 * 1. **落沙箱，不存 uri**。picker 给的 `file://media/...` 是一次性授权的，
 *    应用重装或清数据后就失效；只有复制进自己的沙箱才算真正持有这张图。
 *
 * 2. **文件名带时间戳**。ArkUI 的 Image 按 src 字符串缓存解码结果，
 *    同名覆盖时它可能继续画缓存里的旧图 —— 表现为"换了头像没反应"。
 *    每次换名 = 换了 src = 必定重新解码。
 *
 * 3. **读之前验文件在不在**。用户在系统里清过应用数据、或某次复制中途失败，
 *    库里会留下指向空气的路径，直接喂给 Image 会渲染成空白方块。
 *    这种时候应当安静地退回默认头像，而不是显示一个洞。
 */
export class AvatarStore {
  /** 自定义头像的沙箱绝对路径；没设过 / 文件已丢 ⇒ 空串 */
  static async customPath(): Promise<string> {
    try {
      const p: string | undefined = await KvRepo.get(KEY_AVATAR);
      if (p === undefined || p.length === 0) {
        return '';
      }
      if (!fileIo.accessSync(p)) {
        Log.w(`头像文件已不在，回退默认：${p}`);
        return '';
      }
      return p;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`头像路径读取失败，回退默认：${err.message}`);
      return '';
    }
  }

  /** 能直接喂给 Image 的 src；空串表示调用方该用 $rawfile('avatar_default.png') */
  static async imageSrc(): Promise<string> {
    const p: string = await AvatarStore.customPath();
    if (p.length === 0) {
      return '';
    }
    return fileUri.getUriFromPath(p);
  }

  static async hasCustom(): Promise<boolean> {
    const p: string = await AvatarStore.customPath();
    return p.length > 0;
  }

  /**
   * 拉起系统相册选一张图。
   *
   * 返回新头像的沙箱路径；**用户取消时返回空串** —— 那不是错误，
   * 调用方不要因此弹 toast（"你取消了"这种提示很烦人）。
   *
   * picker 免权限：选择动作是用户自己发起的，系统不要求应用申请读相册权限。
   */
  static async pickFromGallery(ctx: common.Context): Promise<string> {
    const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opt.maxSelectNumber = 1;
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
    const uris: Array<string> = res.photoUris;
    if (uris.length === 0) {
      Log.i('头像选择被取消');
      return '';
    }
    return await AvatarStore.installFrom(ctx, uris[0], 'picker');
  }

  /**
   * 从 rawfile 装一张内置图。
   * 用途：无头自检，以及相册为空时（模拟器上没法程序化往媒体库塞图）的兜底演示。
   */
  static async installFromRaw(ctx: common.Context, rawName: string): Promise<string> {
    const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(rawName);
    const dest: string = AvatarStore.destPath(ctx);
    const f: fileIo.File = fileIo.openSync(dest,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(f);
    }
    await AvatarStore.commit(ctx, dest);
    Log.i(`头像已更新（来源 rawfile ${rawName}）：${dest} ${fileIo.statSync(dest).size} 字节`);
    return dest;
  }

  /** 从任意可读 uri（picker 结果 / 沙箱路径）复制进沙箱并设为当前头像 */
  static async installFrom(ctx: common.Context, src: string, from: string): Promise<string> {
    const dest: string = AvatarStore.destPath(ctx);
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(f.fd, dest);
    } finally {
      if (f !== undefined) {
        fileIo.closeSync(f);
      }
    }
    await AvatarStore.commit(ctx, dest);
    Log.i(`头像已更新（来源 ${from}）：${dest} ${fileIo.statSync(dest).size} 字节`);
    return dest;
  }

  /** 恢复默认：抹掉 KV 与沙箱文件 */
  static async reset(): Promise<void> {
    const old: string | undefined = await KvRepo.get(KEY_AVATAR);
    await KvRepo.del(KEY_AVATAR);
    AvatarStore.dropFile(old);
    Log.i('头像已恢复默认');
  }

  private static destPath(ctx: common.Context): string {
    return `${ctx.filesDir}/avatar_${Date.now()}.png`;
  }

  /** 先落库再删旧图：反过来一旦删完就崩，库里会留下一个指向空路径的记录。 */
  private static async commit(ctx: common.Context, dest: string): Promise<void> {
    const old: string | undefined = await KvRepo.get(KEY_AVATAR);
    await KvRepo.put(KEY_AVATAR, dest);
    if (old !== undefined && old.length > 0 && old !== dest) {
      AvatarStore.dropFile(old);
    }
  }

  private static dropFile(p: string | undefined): void {
    if (p === undefined || p.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`旧头像删除失败（不影响功能）：${err.message}`);
    }
  }
}
