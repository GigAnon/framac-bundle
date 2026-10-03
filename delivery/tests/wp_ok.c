/* WP acceptance sample: every goal must be proved by each bundled prover.
   The quantified loop invariant cannot be discharged by Qed alone. */

/*@ requires n >= 0 && \valid_read(a + (0 .. n-1));
    assigns \nothing;
    ensures -1 <= \result < n;
    ensures 0 <= \result ==> a[\result] == x;
    ensures \result == -1 ==> \forall integer k; 0 <= k < n ==> a[k] != x;
*/
int find(const int *a, int n, int x)
{
  /*@ loop invariant 0 <= i <= n;
      loop invariant \forall integer k; 0 <= k < i ==> a[k] != x;
      loop assigns i;
      loop variant n - i;
  */
  for (int i = 0; i < n; i++)
    if (a[i] == x) return i;
  return -1;
}

/*@ requires \valid(p) && \valid(q) && \separated(p, q);
    assigns *p, *q;
    ensures *p == \old(*q) && *q == \old(*p);
*/
void swap(int *p, int *q)
{
  int t = *p; *p = *q; *q = t;
}

/*@ assigns \nothing;
    ensures \result >= a && \result >= b;
    ensures \result == a || \result == b;
*/
int max(int a, int b)
{
  return a > b ? a : b;
}

/*@ requires n > 0 && \valid_read(a + (0 .. n-1));
    assigns \nothing;
    ensures \forall integer k; 0 <= k < n ==> \result >= a[k];
    ensures \exists integer k; 0 <= k < n && \result == a[k];
*/
int array_max(const int *a, int n)
{
  int m = a[0];
  /*@ loop invariant 1 <= i <= n;
      loop invariant \forall integer k; 0 <= k < i ==> m >= a[k];
      loop invariant \exists integer k; 0 <= k < i && m == a[k];
      loop assigns i, m;
      loop variant n - i;
  */
  for (int i = 1; i < n; i++)
    if (a[i] > m) m = a[i];
  return m;
}
