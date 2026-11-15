// =====================================================================
// Portfolio 4 - Odunlade_Oluwaseun_301931438_03_transaction.js
// Multi-document ACID transaction in MongoDB (requires a replica set):
// the checkout of Portfolio 3 re-implemented on the document model.
// =====================================================================
db = db.getSiblingDB("seunbaba");
const X = db.products.findOne({ sku: "SBB-000100" }), Y = db.products.findOne({ sku: "SBB-000101" });
const stockOf = id => db.products.findOne({ _id: id }, { "stock.wh1": 1 }).stock.wh1;
const nextId = () => db.orders.find().sort({ _id: -1 }).limit(1).next()._id + 1;

function checkout(basket, label) {
  print(`\n######## ${label} ########`);
  basket.forEach(b => print(`  before: ${b.p.sku} stock.wh1 = ${stockOf(b.p._id)}, requested ${b.qty}`));
  const s = db.getMongo().startSession();
  const sdb = s.getDatabase("seunbaba");
  const orderId = nextId();
  s.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
  try {
    for (const b of basket) {
      // conditional decrement = check and act in ONE atomic operation
      const r = sdb.products.updateOne({ _id: b.p._id, "stock.wh1": { $gte: b.qty } }, { $inc: { "stock.wh1": -b.qty } });
      print(`  [txn] decrement ${b.p.sku} by ${b.qty}: modified=${r.modifiedCount}`);
      if (r.modifiedCount === 0) throw new Error(`insufficient stock for ${b.p.sku}`);
    }
    const total = basket.reduce((t, b) => t + Number(b.p.price.toString()) * b.qty, 0);
    sdb.orders.insertOne({
      _id: orderId, customer: { customer_id: 1207, name: "Chinedu Ibrahim", email: "chinedu.ibrahim1207@outlook.com" },
      status: "PENDING", order_date: new Date(),
      items: basket.map((b, i) => ({ line_no: i + 1, product_id: b.p._id, sku: b.p.sku, name: b.p.name,
                                     qty: NumberInt(b.qty), unit_price: b.p.price, warehouse: "wh1" })),
      totals: { total: NumberDecimal(total.toFixed(2)) }, payments: [], shipment: null });
    print(`  [txn] inserted order ${orderId}`);
    s.commitTransaction();
    print("  COMMITTED");
  } catch (e) {
    s.abortTransaction();
    print(`  ABORTED: ${e.message}`);
  } finally { s.endSession(); }
  basket.forEach(b => print(`  after : ${b.p.sku} stock.wh1 = ${stockOf(b.p._id)}`));
  print(`  order ${orderId} exists? ${db.orders.countDocuments({ _id: orderId }) === 1}`);
}

checkout([{ p: X, qty: 2 }, { p: Y, qty: 1 }], "T1 commit: 2 x product A + 1 x product B");
checkout([{ p: X, qty: 1 }, { p: Y, qty: 100000 }], "T2 abort: line 1 succeeds, line 2 fails -> line 1 is undone");

print("\n######## T3 write conflict: two concurrent transactions update the same product ########");
const s1 = db.getMongo().startSession(), s2 = db.getMongo().startSession();
s1.startTransaction(); s2.startTransaction();
s1.getDatabase("seunbaba").products.updateOne({ _id: X._id }, { $inc: { "stock.wh1": -1 } });
print("  session 1 updated the product (uncommitted)");
try {
  s2.getDatabase("seunbaba").products.updateOne({ _id: X._id }, { $inc: { "stock.wh1": -1 } });
  print("  session 2 updated too (unexpected)");
} catch (e) {
  print(`  session 2: ${e.codeName} (code ${e.code}), labels=${JSON.stringify(e.errorLabels)}`);
  print("  -> driver/application should retry the whole transaction (TransientTransactionError)");
}
try { s2.abortTransaction(); } catch (e) {}
s1.commitTransaction(); s1.endSession(); s2.endSession();
print(`  final ${X.sku} stock.wh1 = ${stockOf(X._id)} (exactly one decrement applied)`);
