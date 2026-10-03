/* WP negative sample: the postcondition is false, so it must NOT be proved.
   Guards against a prover setup that silently "proves" everything. */

/*@ assigns \nothing;
    ensures \result > a;
*/
int wrong(int a, int b)
{
  return b;
}
