let recorded = 0;
export const reset = () => {
  recorded = 0;
};
export const record = (n) => () => {
  recorded += n;
};
export const total = () => recorded;