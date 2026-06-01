import * as Lib from "../Lib/index.js";
const fib = n$p => {
  const go = go$a0$copy => go$a1$copy => go$a2$copy => {
    let go$a0 = go$a0$copy, go$a1 = go$a1$copy, go$a2 = go$a2$copy, go$c = true, go$r;
    while (go$c) {
      const a = go$a0, b = go$a1, k = go$a2;
      if (Lib.eqI(k)(1)) {
        go$c = false;
        go$r = a;
        continue;
      }
      go$a0 = b;
      go$a1 = Lib.addI(a)(b);
      go$a2 = Lib.subI(k)(1);
    }
    return go$r;
  };
  return go(1)(1)(n$p);
};
export {fib};
