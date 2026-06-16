// import { Left, Right } from "../Data.Either/index.js";
// import { Unexpected, MissingValue } from "../PureScript.ExternsFile.Decoder.Monad/index.js";

export const readAt_ = function (utils, idx, fgn) {
  if (!Array.isArray(fgn)) {
    return utils.Left(utils.Unexpected("Expecting array, got " + typeof fgn));
  }
  if (fgn[idx] === void 0) {
    return utils.Left(utils.MissingValue);
  }
  if (fgn.length < idx) {
    return utils.Left(utils.Unexpected("Got an array of length " + fgn.length + ", which is too small to get element at " + idx));
  }
  return utils.Right(fgn[idx]);
};

export const asInt_ = function (utils, n, fgn) {
  if (typeof fgn === "number") {
    return ((fgn | 0) === fgn)
      ? utils.Right(fgn)
      : utils.Left(utils.Unexpected("Expecting integer, got a floating point number"));
  }
  return utils.Left(utils.Unexpected("Expecting integer, got " + typeof fgn));
};

export const asArray_ = function (utils, fgn) {
  if (!Array.isArray(fgn)) {
    return utils.Left(utils.Unexpected("Expecting array, got " + typeof fgn));
  }
  return utils.Right(fgn);
};
