import {addI, eqI, mulI, subI} from "./foreign.js";
const incr = n => addI(n)(1);
const decr = n => subI(n)(1);
export {decr, incr};
export * from "./foreign.js";
