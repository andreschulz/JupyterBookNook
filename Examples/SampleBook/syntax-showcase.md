---
title: Syntax showcase
---

(sec-showcase)=
# Syntax showcase

This page shows every kind of MyST syntax the editor colours. It is not in the
table of contents. Misspelled words in prose, like *speling*, are underlined,
but code, math and labels are not: {ref}`sec-xyzzy`, $\alpah + \betta$, `fooo`.

## Inline syntax

Some **strong text**, some _emphasis_, a [link to the intro](intro.md),
a bare URL https://jupyterbook.org, a substitution {{ projekt }} and a footnote[^nte].

[^nte]: The footnote text.

## Directives

:::{note} Choosing the step size
The step size $\eta$ is often called the *learning rate*.
:::

:::{warning}
Too large a step makes gradient descent diverge.
:::

```{figure} images/plott.png
:name: fig-plott
:width: 80%
A caption with a *word* in it.
```

```{code-cell} python
# this is a comment, not a heading
import numpy as np
x = np.linspace(0, 1, 100)
```

```{math}
:label: eq-quadratik
f(x) = \tfrac{1}{2} x^\top A x - b^\top x
```

$$
\nabla f(x) = A x - b
$$

## Lists and quotes

- First item with {cite}`smith2020`
- Second item
1. Numbered item

> A quotation with $x^2$ in it.

% A MyST comment line: not spell checked.
<!-- An HTML comment
over two lines -->

### A third-level heading ###
