#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Train the 64-64-32-10 MLP of ../mlp.c on the 8 x 8 digits of scikit-learn (the UCI optical digits), quantize it to int8 the way TFLite does
(symmetric per-tensor weights, asymmetric int8 activations, int32 biases, Q31 multiplier and shift per layer) and write digits_model.h for ../digits.c.

The integer model below is muRISCV-NN's fully connected layer and its requantization, bit for bit (muriscv_nn_requantize of the default branch:
rounding doubling high multiply, then a rounding divide by a power of two, midpoints away from zero), so its accuracy and its predictions are what the
chip must reproduce.  Needs numpy and scikit-learn (for the data only; training is plain numpy):  python3 train_digits.py [--samples 200]
"""

import argparse
from pathlib import Path

import numpy as np
from sklearn.datasets import load_digits

SIZES = (64, 64, 32, 10)
Q_MIN, Q_MAX = -128, 127


def train(x, y, seed=1, epochs=300, lr=3e-3, batch=64):
    """Float MLP (ReLU, softmax cross entropy, Adam); returns [(W, b), ...] with W of shape (out, in)."""
    rng = np.random.default_rng(seed)
    params = []
    for i, o in zip(SIZES[:-1], SIZES[1:]):
        params.append([rng.normal(0, np.sqrt(2.0 / i), (o, i)), np.zeros(o)])
    m = [[np.zeros_like(p) for p in layer] for layer in params]
    v = [[np.zeros_like(p) for p in layer] for layer in params]
    step = 0
    onehot = np.eye(10)[y]
    for _ in range(epochs):
        order = rng.permutation(len(x))
        for s in range(0, len(x), batch):
            idx = order[s : s + batch]
            acts = [x[idx]]
            for k, (w, b) in enumerate(params):
                z = acts[-1] @ w.T + b
                acts.append(np.maximum(z, 0) if k < len(params) - 1 else z)
            logits = acts[-1] - acts[-1].max(axis=1, keepdims=True)
            p = np.exp(logits)
            p /= p.sum(axis=1, keepdims=True)
            grad = (p - onehot[idx]) / len(idx)
            step += 1
            for k in range(len(params) - 1, -1, -1):
                gw, gb = grad.T @ acts[k], grad.sum(axis=0)
                if k > 0:
                    grad = (grad @ params[k][0]) * (acts[k] > 0)
                for j, g in enumerate((gw, gb)):
                    m[k][j] = 0.9 * m[k][j] + 0.1 * g
                    v[k][j] = 0.999 * v[k][j] + 0.001 * g * g
                    params[k][j] -= lr * (m[k][j] / (1 - 0.9**step)) / (np.sqrt(v[k][j] / (1 - 0.999**step)) + 1e-8)
    return params


def forward_float(params, x):
    a = x
    acts = []
    for k, (w, b) in enumerate(params):
        a = a @ w.T + b
        if k < len(params) - 1:
            a = np.maximum(a, 0)
        acts.append(a)
    return acts


def quantize_multiplier(real):
    """real = mult / 2**31 * 2**shift with mult in [2**30, 2**31): the library's quant_params."""
    m, e = np.frexp(real)
    mult = round(m * (1 << 31))
    if mult == 1 << 31:
        mult //= 2
        e += 1
    return mult, int(e)


def requantize(val, mult, shift):
    """muriscv_nn_requantize, default branch, on an int64 array: left shift if shift > 0, rounding doubling high multiply (midpoint up),
    rounding divide by 2**-shift (midpoint away from zero)."""
    left, right = max(shift, 0), max(-shift, 0)
    r = ((val << left) * mult + (1 << 30)) >> 31
    if right:
        mask = (1 << right) - 1
        q = r >> right
        threshold = (mask >> 1) + (q < 0)
        q = q + ((r & mask) > threshold)
        return q
    return r


def quantize_model(params, x_train):
    """Per-tensor int8 model; returns the list of layer dicts and the input quantization (scale, zero point)."""
    acts = forward_float(params, x_train)
    s_in, zp_in = 1.0 / 255.0, -128        # inputs in [0, 1]: q = round(x / s) + zp
    layers = []
    for k, (w, b) in enumerate(params):
        last = k == len(params) - 1
        s_w = np.abs(w).max() / 127.0
        wq = np.clip(np.round(w / s_w), -127, 127).astype(np.int8)
        bq = np.round(b / (s_in * s_w)).astype(np.int32)
        if last:
            s_out, zp_out = np.abs(acts[k]).max() / 127.0, 0
        else:
            s_out, zp_out = np.percentile(acts[k], 99.9) / 255.0, -128      # ReLU: the real 0 is the zero point
        mult, shift = quantize_multiplier(s_in * s_w / s_out)
        layers.append({"w": wq, "b": bq, "in_off": -zp_in, "out_off": zp_out, "mult": mult, "shift": shift, "amin": Q_MIN, "amax": Q_MAX})
        s_in, zp_in = s_out, zp_out
    return layers


def forward_int(layers, xq):
    """The integer network on a (n, 64) int8 array: every layer's int8 output."""
    a = xq.astype(np.int64)
    outs = []
    for ly in layers:
        acc = (a + ly["in_off"]) @ ly["w"].astype(np.int64).T + ly["b"].astype(np.int64)
        a = np.clip(requantize(acc, ly["mult"], ly["shift"]) + ly["out_off"], ly["amin"], ly["amax"])
        outs.append(a)
    return outs


def c_array(name, values, ctype, per_line=16):
    flat = [int(v) for v in np.asarray(values).ravel()]
    lines = [f"static const {ctype} {name}[{len(flat)}] __attribute__((aligned(4))) = {{"]
    for i in range(0, len(flat), per_line):
        lines.append("    " + ", ".join(str(v) for v in flat[i : i + per_line]) + ",")
    lines.append("};")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--samples", type=int, default=200, help="test samples embedded in the header for the chip")
    ap.add_argument("--out", default=str(Path(__file__).with_name("digits_model.h")))
    args = ap.parse_args()

    data = load_digits()
    x, y = data.data / 16.0, data.target
    order = np.random.default_rng(0).permutation(len(x))
    n_train = 1200
    tr, te = order[:n_train], order[n_train:]
    params = train(x[tr], y[tr])
    float_acc = float((forward_float(params, x[te])[-1].argmax(axis=1) == y[te]).mean())
    layers = quantize_model(params, x[tr])

    def quant_input(a):
        return (np.round(a * 255.0).astype(np.int64) - 128).astype(np.int8)

    xq_te = quant_input(x[te])
    logits = forward_int(layers, xq_te)[-1]
    pred = logits.argmax(axis=1)
    int_acc = float((pred == y[te]).mean())
    n = args.samples
    sub_acc = float((pred[:n] == y[te][:n]).mean())
    print(f"test set {len(te)} samples: float {float_acc:.4f}, int8 {int_acc:.4f}; first {n}: int8 {sub_acc:.4f}")
    for k, ly in enumerate(layers):
        print(f"layer {k + 1}: in_off {ly['in_off']}, out_off {ly['out_off']}, mult {ly['mult']}, shift {ly['shift']}")

    out = [
        "/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1",
        " * Generated by model/train_digits.py (do not edit): the 64-64-32-10 int8 MLP trained on the 8 x 8 digits of scikit-learn, its quantization",
        f" * (muRISCV-NN's fully connected layer: input offset, Q31 multiplier and shift, output offset, clamp), and {n} test samples with their labels",
        f" * and the classes the host's bit-exact integer model gives.  Accuracy on the {len(te)} test samples: float {float_acc:.4f}, int8 {int_acc:.4f};",
        f" * on the {n} embedded ones: int8 {sub_acc:.4f}. */",
        "#ifndef DIGITS_MODEL_H",
        "#define DIGITS_MODEL_H",
        "",
        "#include <stdint.h>",
        "",
        f"#define DIGITS_N {n}",
        f"#define DIGITS_EXPECTED_CORRECT {int((pred[:n] == y[te][:n]).sum())}",
        "",
        "struct digits_layer {",
        "    int in, out;",
        "    int32_t in_off, out_off, mult, shift, amin, amax;",
        "};",
        "",
        "static const struct digits_layer DL[3] = {",
    ]
    for k, ly in enumerate(layers):
        out.append(
            f"    {{ {SIZES[k]}, {SIZES[k + 1]}, {ly['in_off']}, {ly['out_off']}, {ly['mult']}, {ly['shift']}, {ly['amin']}, {ly['amax']} }},"
        )
    out.append("};")
    for k, ly in enumerate(layers):
        out += ["", c_array(f"DW{k + 1}", ly["w"], "int8_t"), "", c_array(f"DB{k + 1}", ly["b"], "int32_t", 8)]
    out += [
        "",
        c_array("DX", xq_te[:n], "int8_t", 16),
        "",
        c_array("DLABEL", y[te][:n], "uint8_t", 32),
        "",
        c_array("DREF", pred[:n], "uint8_t", 32),
        "",
        "#endif",
        "",
    ]
    Path(args.out).write_text("\n".join(out))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
