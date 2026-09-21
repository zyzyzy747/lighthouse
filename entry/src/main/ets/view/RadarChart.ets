/**
 * 灯塔 Lighthouse · 六维能力雷达图
 * 目标路径：entry/src/main/ets/view/RadarChart.ets
 * ------------------------------------------------------------------
 * 用 Canvas 手绘。为什么不用现成图表库：一多部署要求零额外依赖，
 * 且雷达图只要 6 个轴，自己画比引入库更可控。
 *
 * ⚠ ArkUI V1 的坑（本文件已规避）：
 *   如果直接把 number[] 当 @Prop 传进来，数组内容变化时**不保证触发重绘**。
 *   所以对外暴露的是序列化后的字符串 scoresKey（值类型），
 *   用 @Watch 监听它变化再重画。UI 层只要拼好 "12,34,56,78,90,45" 传进来即可。
 *
 * 画布配色跟随应用自身的深色主题（应用内是深色底，与 IDE 主题无关）。
 */

@Component
export struct RadarChart {
  /**
   * 六个分数，逗号分隔，顺序必须与 RadarDef.KEYS 一致。
   * 形如 "34,52,61,0,45,70"。值变化即触发重绘。
   */
  @Prop @Watch('onKeyChanged') scoresKey: string;
  /**
   * 画布边长（vp）。
   * ⚠ 不能叫 size —— 会撞上 CustomComponent 基类的 size(value: SizeOptions) 方法，
   *   报 "Property 'size' is not assignable to the same property in base type"。
   *   同类已知冲突名：position、tabIndex、size。自定义组件字段一律绕开这些。
   */
  @Prop canvasSize: number;
  /** 是否画刻度环的数字，小尺寸时可关掉 */
  @Prop showScale: boolean;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  onKeyChanged(): void {
    if (this.ready) {
      this.draw();
    }
  }

  build() {
    Canvas(this.ctx)
      .width(this.canvasSize)
      .height(this.canvasSize)
      .onReady(() => {
        this.ready = true;
        this.draw();
      })
  }

  /* ---------------- 绘制 ---------------- */

  private parse(): number[] {
    const parts: string[] = this.scoresKey.length > 0 ? this.scoresKey.split(',') : [];
    const out: number[] = [];
    for (let i: number = 0; i < 6; i++) {
      if (i < parts.length) {
        const v: number = Number.parseInt(parts[i], 10);
        out.push(isNaN(v) ? 0 : Math.max(0, Math.min(100, v)));
      } else {
        out.push(0);
      }
    }
    return out;
  }

  private draw(): void {
    const n: number = 6;
    const s: number = this.canvasSize;
    const cx: number = s / 2;
    const cy: number = s / 2;
    // 留出四周给轴标签
    const labelPad: number = this.canvasSize >= 220 ? 40 : 30;
    const R: number = s / 2 - labelPad;

    this.ctx.clearRect(0, 0, s, s);

    const scores: number[] = this.parse();

    /* --- 1. 同心网格 --- */
    for (let ring: number = 4; ring >= 1; ring--) {
      const rr: number = R * ring / 4;
      this.polyPath(cx, cy, rr, n);
      // 最外圈稍亮，形成边框感
      this.ctx.strokeStyle = ring === 4 ? '#2C3D5E' : '#1D2A44';
      this.ctx.lineWidth = 1;
      this.ctx.stroke();
    }

    /* --- 2. 轴线 --- */
    this.ctx.strokeStyle = '#1D2A44';
    this.ctx.lineWidth = 1;
    for (let i: number = 0; i < n; i++) {
      const a: number = this.angleOf(i, n);
      this.ctx.beginPath();
      this.ctx.moveTo(cx, cy);
      this.ctx.lineTo(cx + Math.cos(a) * R, cy + Math.sin(a) * R);
      this.ctx.stroke();
    }

    /* --- 3. 刻度数字（25/50/75/100），小尺寸不画 --- */
    if (this.showScale) {
      this.ctx.fillStyle = '#4A5D80';
      this.ctx.font = '10px sans-serif';
      this.ctx.textAlign = 'center';
      this.ctx.fillText('25', cx, cy - R * 0.25 + 3);
      this.ctx.fillText('50', cx, cy - R * 0.5 + 3);
      this.ctx.fillText('75', cx, cy - R * 0.75 + 3);
    }

    /* --- 4. 数据多边形 --- */
    this.ctx.beginPath();
    for (let i: number = 0; i < n; i++) {
      const a: number = this.angleOf(i, n);
      const r: number = R * scores[i] / 100;
      const x: number = cx + Math.cos(a) * r;
      const y: number = cy + Math.sin(a) * r;
      if (i === 0) {
        this.ctx.moveTo(x, y);
      } else {
        this.ctx.lineTo(x, y);
      }
    }
    this.ctx.closePath();
    this.ctx.fillStyle = 'rgba(74,158,255,0.26)';
    this.ctx.fill();
    this.ctx.strokeStyle = '#4A9EFF';
    this.ctx.lineWidth = 2;
    this.ctx.stroke();

    /* --- 5. 顶点圆点：低分标红色警示，高分标绿色，一眼看出短板 --- */
    for (let i: number = 0; i < n; i++) {
      const a: number = this.angleOf(i, n);
      const r: number = R * scores[i] / 100;
      const x: number = cx + Math.cos(a) * r;
      const y: number = cy + Math.sin(a) * r;
      this.ctx.beginPath();
      this.ctx.arc(x, y, 3.2, 0, Math.PI * 2);
      if (scores[i] <= 0) {
        this.ctx.fillStyle = '#3A4A66';       // 未涉及：灰点落在圆心附近
      } else if (scores[i] < 45) {
        this.ctx.fillStyle = '#FF5C5C';       // 短板：红
      } else if (scores[i] < 70) {
        this.ctx.fillStyle = '#FFB020';       // 一般：橙
      } else {
        this.ctx.fillStyle = '#3DD68C';       // 良好：绿
      }
      this.ctx.fill();
    }

    /* --- 6. 轴标签 --- */
    this.ctx.font = this.canvasSize >= 220 ? '11px sans-serif' : '9.5px sans-serif';
    for (let i: number = 0; i < n; i++) {
      const label: string = RadarShort.LABELS[i];
      const a: number = this.angleOf(i, n);
      const lx: number = cx + Math.cos(a) * (R + 17);
      const ly: number = cy + Math.sin(a) * (R + 17);
      const v: number = scores[i];

      this.ctx.fillStyle = v <= 0 ? '#5A6B8A' : '#C7D4E8';
      this.ctx.textAlign = 'center';
      this.ctx.textBaseline = 'middle';
      this.ctx.fillText(label, lx, ly - 6);

      // 分数紧贴标签下方，比只看形状更直观
      this.ctx.fillStyle = v <= 0 ? '#3A4A66'
        : (v < 45 ? '#FF5C5C' : (v < 70 ? '#FFB020' : '#3DD68C'));
      this.ctx.font = this.canvasSize >= 220 ? 'bold 11px sans-serif' : 'bold 9.5px sans-serif';
      this.ctx.fillText(v > 0 ? `${v}` : '—', lx, ly + 8);
      this.ctx.font = this.canvasSize >= 220 ? '11px sans-serif' : '9.5px sans-serif';
    }
  }

  /** 第 i 个轴的角度。从正上方开始顺时针，这样雷达是"正着"的 */
  private angleOf(i: number, n: number): number {
    return -Math.PI / 2 + i * (Math.PI * 2 / n);
  }

  /** 画一个以 (cx,cy) 为心、半径 r 的正 n 边形路径 */
  private polyPath(cx: number, cy: number, r: number, n: number): void {
    this.ctx.beginPath();
    for (let i: number = 0; i < n; i++) {
      const a: number = this.angleOf(i, n);
      const x: number = cx + Math.cos(a) * r;
      const y: number = cy + Math.sin(a) * r;
      if (i === 0) {
        this.ctx.moveTo(x, y);
      } else {
        this.ctx.lineTo(x, y);
      }
    }
    this.ctx.closePath();
  }
}

/** 与 RadarDef.KEYS 一一对应的短标签，避免 Canvas 里文字互相压住 */
class RadarShort {
  static readonly LABELS: string[] = ['Java', '数据库', '框架', '计基', '算法', '项目'];
}
