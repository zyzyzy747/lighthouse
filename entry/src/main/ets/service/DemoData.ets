import {
  Application, AppStatus, EventNode, EventType, emptyApplication,
  ReviewRecord, InterviewRound
} from '../common/Types';
import { ApplicationRepo } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { Log } from '../common/Logger';

/**
 * 演示数据。
 *
 * 用途：① 第一次装上应用时快速看到成品形态；② 答辩演示的保底数据。
 * ⚠ 正式提交前建议替换成自己的真实投递记录 —— 被问「数据哪来的」时，
 *   答「这是我秋招的真实记录」比任何虚构 demo 都有分量。
 *
 * 关于复盘样本的写法（很重要）：
 *   三份回忆刻意写成三种典型形态 ——
 *   ① 技术面（有来有回，雷达起伏大，最适合演示）
 *   ② HR 面（技术维度全未涉及，展示「不编造」这条规则真的生效）
 *   ③ 二面被追问（项目强、八股弱，展示雷达能定位短板）
 *   radarJson 一律留空：演示时要**现场点「生成能力雷达」**，
 *   让评委看到分析真的在跑，而不是打开就有张画好的图。
 */
class DemoApp {
  company: string = '';
  job: string = '';
  city: string = '';
  channel: string = '';
  status: string = '';
  salaryMin: number = 0;
  salaryMax: number = 0;
  /** 事件发生在几小时后；<=0 表示不建事件 */
  eventInHours: number = 0;
  eventType: string = EventType.OTHER;
  /** 投递发生在几天前 */
  appliedDaysAgo: number = 1;
  /**
   * 该岗位的 JD 原文。
   * 演示数据里给一条带上，有两个用处：
   *   ① 答辩现场不用手打一大段中文，点开「JD 匹配分析」就能直接看结果；
   *   ② 演示库本身也应该是"完整"的 —— 一条填好了 JD 的记录，比八条空白的更像真实用户的数据。
   */
  jdText: string = '';
  /**
   * 备注。
   * 和 jdText 同样的道理：一条填写完整的记录，比八条空白的更像真实用户的数据。
   * 顺便也让「备注 + 语音速记」这个入口在演示库里有现成的东西可看。
   */
  note: string = '';

  constructor(company: string, job: string, city: string, channel: string, status: string,
    salaryMin: number, salaryMax: number, appliedDaysAgo: number,
    eventInHours: number, eventType: string, jdText: string = '', note: string = '') {
    this.company = company;
    this.job = job;
    this.city = city;
    this.channel = channel;
    this.status = status;
    this.salaryMin = salaryMin;
    this.salaryMax = salaryMax;
    this.appliedDaysAgo = appliedDaysAgo;
    this.eventInHours = eventInHours;
    this.eventType = eventType;
    this.jdText = jdText;
    this.note = note;
  }
}

/** 公司名 → 已插入的 appId，用于把复盘挂到正确的投递上 */
class DemoAppId {
  company: string = '';
  id: number = 0;

  constructor(company: string, id: number) {
    this.company = company;
    this.id = id;
  }
}

class DemoReview {
  company: string = '';
  round: string = '';
  interviewer: string = '';
  narration: string = '';
  daysAgo: number = 1;

  constructor(company: string, round: string, interviewer: string,
    narration: string, daysAgo: number) {
    this.company = company;
    this.round = round;
    this.interviewer = interviewer;
    this.narration = narration;
    this.daysAgo = daysAgo;
  }
}

const HOUR: number = 60 * 60 * 1000;
const DAY: number = 24 * HOUR;

/** 真实面试/笔试会落在这几个钟点上 */
const CLOCK_OFFICE: number[][] = [[9, 0], [10, 0], [14, 0], [15, 0], [19, 0]];

/**
 * 把「now + N 小时」对齐到最近的合理钟点。
 *
 * 为什么需要这一步：直接加小时会算出「明天 21:18 一面」——数据本身没错，
 * 但一眼就是假的。倒计时是相对量，怎么算都成立；而「几点面试」是绝对量，
 * 必须像真的，否则演示时被评委一眼看穿整组数据是编的。
 *
 * 截止类节点特殊处理：落在当天 23:59（投递截止就是这么表达的）。
 */
function alignToClock(ts: number, now: number, isDeadline: boolean): number {
  let best: number = 0;
  if (isDeadline) {
    const d: Date = new Date(ts);
    d.setHours(23, 59, 0, 0);
    best = d.getTime();
  } else {
    let bestGap: number = 2147483647;
    for (let i: number = 0; i < CLOCK_OFFICE.length; i++) {
      const c: Date = new Date(ts);
      c.setHours(CLOCK_OFFICE[i][0], CLOCK_OFFICE[i][1], 0, 0);
      const gap: number = Math.abs(c.getTime() - ts);
      if (gap < bestGap) {
        bestGap = gap;
        best = c.getTime();
      }
    }
  }
  // 对齐后若落到过去就顺延一天，保证倒计时始终为正（否则卡片一上来就显示「已逾期」）
  return best <= now ? best + DAY : best;
}

/**
 * 演示用 JD：一段真实的 Java 后端校招要求。
 *
 * 刻意把它写得**覆盖三个层次**：底牌里有的（Java/MySQL/Spring/Redis）、
 * 底牌里写了薄弱的（分布式、消息队列、容器化）、以及底牌完全没提的。
 * 这样点一次「开始分析」就能同时看到「具备 / 部分 / 缺失」三种状态 ——
 * 如果 JD 只写两三条，结果会是一片绿或一片红，看不出分析到底做了什么。
 */
const DEMO_JD: string = '岗位职责：\n'
  + '1. 参与公司 ERP 产品的后端服务设计与开发，负责核心业务模块的接口实现；\n'
  + '2. 基于 Spring Boot + MyBatis 完成业务功能开发，编写高质量、可维护的代码；\n'
  + '3. 参与数据库表结构设计与 SQL 优化，保障高频查询的性能；\n'
  + '4. 配合前端完成接口联调，参与需求评审与技术方案讨论。\n'
  + '\n'
  + '任职要求：\n'
  + '1. 本科及以上学历，计算机相关专业，2026 届毕业生；\n'
  + '2. 熟悉 Java 基础，理解集合、多线程与 JVM 内存模型；\n'
  + '3. 熟悉 Spring Boot、MyBatis 等主流框架，了解 IoC 与 AOP 原理；\n'
  + '4. 熟悉 MySQL，掌握索引原理与事务隔离级别；\n'
  + '5. 熟悉 Redis 等缓存中间件，了解分布式锁的常见实现；\n'
  + '6. 熟悉 Linux 常用命令，能独立完成服务部署与日志排查；\n'
  + '7. 有良好的沟通能力与团队协作意识。\n'
  + '\n'
  + '加分项：\n'
  + '1. 有分布式系统或微服务（Spring Cloud / Dubbo）实践经验；\n'
  + '2. 了解 Kafka、RocketMQ 等消息队列的使用场景；\n'
  + '3. 熟悉 Docker 容器化部署，有 CI/CD 实践经验。';

const DEMO_APPS: DemoApp[] = [
  // 第 9 个参数是「距现在多少小时」，会经 alignToClock 落到 9:00/10:00/14:00/15:00/19:00
  // 这几个真实钟点上 —— 凑出「明天 14:00 一面」而不是「明天 21:18 一面」
  // ⚠ 后面两个参数是 jdText / note，结构说明见 make_voice_clip 同款注释：
  //   长参数表**要数位置**，别照顺序猜（这个项目已经栽过一次）。
  new DemoApp('精测电子', 'Java 后端开发', '武汉', '官网', AppStatus.INTERVIEW, 15, 25, 12, 18, EventType.INTERVIEW,
    '', 'HR 说一面过了，等二面通知；面试官是中间件组的，问了不少并发'),
  new DemoApp('光庭信息', 'Java 开发工程师', '武汉', 'BOSS', AppStatus.WRITTEN, 12, 20, 9, 44, EventType.WRITTEN),
  // ⚠ 中望软件这条故意投得久一点（9 天，updatedAt 落到 8 天前）：
  //   「我的」页有一张「投出去 7 天没动静」的跟进提醒卡，阈值是 7 天。
  //   演示库如果一条都够不着，那张卡在演示里永远看不见 ——
  //   而这个"投出去石沉大海"的场景恰恰是秋招最常见的一种。
  new DemoApp('中望软件', 'Java 开发', '广州', '内推', AppStatus.SCREEN, 18, 30, 9, 0, EventType.OTHER),
  new DemoApp('鼎捷软件', '开发工程师', '上海', '牛客', AppStatus.APPLIED, 13, 22, 5, 0, EventType.OTHER, DEMO_JD),
  new DemoApp('用友网络', 'Java 开发', '北京', '官网', AppStatus.REJECTED, 15, 25, 18, 0, EventType.OTHER),
  new DemoApp('金山办公', '服务端开发', '武汉', '内推', AppStatus.OFFER, 20, 35, 21, 0, EventType.OTHER),
  new DemoApp('达梦数据库', '内核开发', '武汉', '官网', AppStatus.APPLIED, 15, 28, 3, 0, EventType.OTHER),
  new DemoApp('明源云', 'Java 开发', '深圳', 'BOSS', AppStatus.WISH, 16, 26, 0, 120, EventType.DEADLINE)
];

const DEMO_REVIEWS: DemoReview[] = [
  new DemoReview(
    '精测电子',
    InterviewRound.TECH_1,
    '技术一面 · 中间件组',
    '一面，面试官是中间件组的，聊了大概四十分钟。' +
    '先让我自我介绍，我讲了实习做的 MES 编码规则管理子系统，他说这个方向跟他们产线系统挺像，就顺着往下问了。' +
    '他问我流水号并发重复是怎么解决的，我说用 MySQL 行锁配合事务，生成前先 select for update 把规则记录锁住。' +
    '他追问并发量再大十倍怎么办，我只说了可以加 Redis，但没讲清楚怎么保证和数据库的一致性，卡住了。' +
    '然后转到八股。问 MySQL 索引为什么用 B+ 树，我答了层高矮、磁盘 IO 少、叶子节点有链表适合范围查询，这题还行。' +
    '又问 RR 隔离级别下幻读怎么解决，我说间隙锁，但他让我具体讲间隙锁锁的是哪段范围，我没答上来，只记得跟索引有关。' +
    'Spring 那边问事务失效的场景，我说了同类内部方法调用不走代理会失效，他点头了；再问 AOP 底层，我说 JDK 动态代理和 CGLIB，但什么场景用哪个说不清楚。' +
    '最后手写快排，写出来了也能说清时间复杂度，但边界漏了等于的情况，被他指出来。' +
    '反问环节我问了团队规模和技术栈，他说是 Java 加自研中间件。' +
    '整体感觉项目能聊，八股不行。',
    10),
  new DemoReview(
    '用友网络',
    InterviewRound.HR,
    'HR 面',
    'HR 面，二十分钟，全程没碰技术。' +
    '问我为什么选 Java 方向，我说实习的时候独立做过一个完整的模块，从建表到页面都是自己写的，觉得这条线能做下去。' +
    '问能不能接受加班，我说可以。问期望薪资，我说 15 到 20k，她记了一下。' +
    '问手上有没有别的offer，我说有一个意向但还在流程里。' +
    '最后问什么时候能到岗，我说毕业前可以先去实习。' +
    '整体就是走流程，没什么压力。',
    16),
  new DemoReview(
    '金山办公',
    InterviewRound.TECH_2,
    '技术二面 · 服务端负责人',
    '二面，面试官是服务端负责人，上来直接问项目。' +
    '我讲编码规则管理子系统的时候他一直在打断，问得很细，比如多租户的数据隔离是怎么做的，我说在 MyBatis-Plus 的拦截器里统一加租户 ID 条件。' +
    '他问如果两条规则并发写进来怎么办，我把行锁那套又讲了一遍，这次他追问锁的粒度，我说是行级锁，他接着问会不会产生死锁，我没答上来。' +
    '然后问 JVM，新生代为什么分 Eden 和 Survivor，我答了复制算法的效率考虑；但 CMS 和 G1 的区别没答上来。' +
    '还问了 TCP 三次握手为什么不是两次，我说防止历史连接，他追问如果第二次握手丢了会怎样，我说客户端会重传，他好像不太满意。' +
    '算法这次没考。最后聊了薪资和团队。',
    5)
];

export class DemoData {
  /** 库里有没有投递记录 */
  static async hasAny(): Promise<boolean> {
    const n: number = await ApplicationRepo.countByStatus(AppStatus.APPLIED);
    if (n > 0) {
      return true;
    }
    const all: Application[] = await ApplicationRepo.listAll();
    return all.length > 0;
  }

  /**
   * 灌入演示数据。已存在数据时不做任何事，避免把用户真实记录搞乱。
   * @returns 实际插入的投递条数，0 表示库非空已跳过
   */
  static async load(): Promise<number> {
    if (await DemoData.hasAny()) {
      Log.i('demo data skipped: db not empty');
      return 0;
    }
    const now: number = Date.now();
    const pairs: DemoAppId[] = [];
    let inserted: number = 0;

    for (let i = 0; i < DEMO_APPS.length; i++) {
      const d: DemoApp = DEMO_APPS[i];
      const app: Application = emptyApplication();
      app.company = d.company;
      app.position = d.job;
      app.city = d.city;
      app.channel = d.channel;
      app.status = d.status;
      app.salaryMin = d.salaryMin;
      app.salaryMax = d.salaryMax;
      app.jdText = d.jdText;
      app.note = d.note;
      app.appliedAt = now - d.appliedDaysAgo * DAY;
      app.updatedAt = now - Math.max(0, d.appliedDaysAgo - 1) * DAY;
      const id: number = await ApplicationRepo.insert(app);
      inserted++;
      pairs.push(new DemoAppId(d.company, id));

      if (d.eventInHours > 0) {
        const ev: EventNode = {
          id: 0,
          appId: id,
          type: d.eventType,
          title: `${d.company} ${DemoData.eventLabel(d.eventType)}`,
          happenAt: alignToClock(now + d.eventInHours * HOUR, now, d.eventType === EventType.DEADLINE),
          done: false,
          note: ''
        };
        await EventRepo.insert(ev);
      }
    }

    // 复盘样本：radarJson 留空，演示时现场生成
    let reviews: number = 0;
    for (let i: number = 0; i < DEMO_REVIEWS.length; i++) {
      const d: DemoReview = DEMO_REVIEWS[i];
      const appId: number = DemoData.findId(pairs, d.company);
      if (appId <= 0) {
        continue;
      }
      const r: ReviewRecord = {
        id: 0,
        appId: appId,
        round: d.round,
        interviewer: d.interviewer,
        narration: d.narration,
        radarJson: '',
        scoreAvg: 0,
        createdAt: now - d.daysAgo * DAY
      };
      await ReviewRepo.insert(r);
      reviews++;
    }

    Log.i(`demo data loaded: ${inserted} apps, ${reviews} reviews`);
    return inserted;
  }

  /** 清掉演示数据里那批（按公司名匹配），便于替换成真实记录 */
  static async clear(): Promise<void> {
    const all: Application[] = await ApplicationRepo.listAll();
    for (let i: number = 0; i < all.length; i++) {
      const name: string = all[i].company;
      for (let j: number = 0; j < DEMO_APPS.length; j++) {
        if (DEMO_APPS[j].company === name) {
          // 先清掉挂在这条投递上的复盘，避免留下孤儿记录
          await DemoData.purgeReviews(all[i].id);
          await ApplicationRepo.remove(all[i].id);
          break;
        }
      }
    }
    Log.i('demo data cleared');
  }

  private static async purgeReviews(appId: number): Promise<void> {
    try {
      const rs: ReviewRecord[] = await ReviewRepo.listByApp(appId);
      for (let i: number = 0; i < rs.length; i++) {
        await ReviewRepo.remove(rs[i].id);
      }
    } catch (e) {
      Log.w('清理复盘失败 appId=' + appId);
    }
  }

  private static findId(pairs: DemoAppId[], company: string): number {
    for (let i: number = 0; i < pairs.length; i++) {
      if (pairs[i].company === company) {
        return pairs[i].id;
      }
    }
    return 0;
  }

  private static eventLabel(t: string): string {
    if (t === EventType.INTERVIEW) {
      return '一面';
    }
    if (t === EventType.WRITTEN) {
      return '在线笔试';
    }
    if (t === EventType.DEADLINE) {
      return '投递截止';
    }
    return '待办';
  }
}
