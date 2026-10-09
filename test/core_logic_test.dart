import 'package:flutter_test/flutter_test.dart';
import 'package:dainpay/main.dart';

void main() {
  group('DainPay money parsing', () {
    test('parses whole and decimal Libyan dinar amounts', () {
      expect(parseCents('187'), 18700);
      expect(parseCents('187.50'), 18750);
      expect(parseCents('187,50'), 18750);
    });

    test('parses Arabic-Indic digits', () {
      expect(parseCents('١٨٧,٥٠'), 18700);
    });
  });

  group('Customer balance ledger', () {
    test('shows prepaid credit instead of reporting a negative debt', () {
      final store = Store();
      store.transactions.addAll([
        Tx(
          id: 'debt-1',
          customerId: 'customer-1',
          type: 'debt',
          amountCents: 5000,
          date: DateTime(2026, 1, 1),
        ),
        Tx(
          id: 'payment-1',
          customerId: 'customer-1',
          type: 'payment',
          amountCents: 23700,
          date: DateTime(2026, 1, 2),
        ),
      ]);

      expect(store.balance('customer-1'), 0);
      expect(store.prepaidCredit('customer-1'), 18700);
      expect(store.risk('customer-1'), 'له رصيد دائن');
      store.dispose();
    });

    test('calculates outstanding debt after partial payment', () {
      final store = Store();
      store.transactions.add(
        Tx(
          id: 'debt-2',
          customerId: 'customer-2',
          type: 'debt',
          amountCents: 25000,
          date: DateTime(2026, 2, 1),
        ),
      );
      store.transactions.add(
        Tx(
          id: 'payment-2',
          customerId: 'customer-2',
          type: 'payment',
          amountCents: 6300,
          date: DateTime(2026, 2, 2),
        ),
      );

      expect(store.balance('customer-2'), 18700);
      expect(store.prepaidCredit('customer-2'), 0);
      store.dispose();
    });
  });
}
