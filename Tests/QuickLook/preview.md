# GitHub Light 预览

白色背景，清晰的文字。支持 **粗体**、*斜体*、[链接](https://github.com) 和行内代码 `config.json`。

## 代码块

```sh
# macOS / Linux
ifconfig | grep "inet " | grep -v 127.0.0.1
```

```json
{
  "name": "Fst",
  "preview": true,
  "count": 42
}
```

## LaTeX 公式

行内公式 $e^{i\pi}+1=0$ 与 $x_i^2 + \alpha$，以及分数 $\frac{a}{b}$。

$$
x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}
$$

\[
\int_0^1 x^2\,dx = \frac{1}{3}
\]

```math
\begin{pmatrix}a & b \\ c & d\end{pmatrix}
```

> 代码中的 `$HOME` 不会被识别成公式。普通金额 $5 和 $10 也保持原样。

- 纯原生渲染
- 本地公式字体
- 不联网加载资源
