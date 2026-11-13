---
title: Gradient Descent
---

(sec-update)=
## The update rule

We minimise a differentiable function $f\colon \mathbb{R}^n \to \mathbb{R}$
by repeatedly stepping against its gradient:

```{math}
:label: eq-update
x_{k+1} = x_k - \eta \, \nabla f(x_k)
```

:::{note} Choosing the step size
The step size $\eta$ is often called the *learning rate*.
:::
