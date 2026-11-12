// Error handling in practice: a tiny bank.

struct Account {
    owner: string
    balance: int

    fn deposit(self, amount: int) -> void! {
        if amount <= 0 {
            fail "deposit must be positive"
        }
        self.balance += amount
    }

    fn withdraw(self, amount: int) -> void! {
        if amount > self.balance {
            fail "{self.owner} only has {self.balance}, cannot withdraw {amount}"
        }
        self.balance -= amount
    }
}

struct Bank {
    accounts: map<string, Account>

    fn open(self, owner: string) -> Account! {
        if self.accounts.has(owner) {
            fail "{owner} already has an account"
        }
        let account = Account{owner: owner, balance: 0}
        self.accounts[owner] = account
        return account
    }

    fn find(self, owner: string) -> Account! {
        return self.accounts.get(owner) catch err {
            fail "no account for {owner}"
        }
    }

    // `?` passes any failure straight to the caller.
    fn transfer(self, from: string, to: string, amount: int) -> void! {
        let source = self.find(from)?
        let target = self.find(to)?
        source.withdraw(amount)?
        target.deposit(amount)?
    }
}

fn new_bank() -> Bank {
    return Bank{accounts: {}}
}

fn main() -> void! {
    let bank = new_bank()
    let alice = bank.open("alice")?
    bank.open("bob")?
    alice.deposit(100)?

    bank.transfer("alice", "bob", 30)?
    print("after transfer: alice={alice.balance} bob={(bank.find("bob")?).balance}")

    // Handle a failure and keep going.
    bank.transfer("alice", "bob", 500) catch err {
        print("transfer refused: {err}")
    }
    bank.transfer("alice", "carol", 5) catch err {
        print("transfer refused: {err}")
    }

    // An unhandled error ends the program with a message and exit code 1.
    bank.open("alice")?
    print("never reached")
}

check "transfer moves money" {
    let bank = new_bank()
    let a = bank.open("a") catch e { return }
    let b = bank.open("b") catch e { return }
    a.deposit(50) catch e { expect(false) }
    bank.transfer("a", "b", 20) catch e { expect(false) }
    expect(a.balance == 30)
    expect(b.balance == 20)
}

check "cannot overdraw" {
    let bank = new_bank()
    let a = bank.open("a") catch e { return }
    let failed = false
    a.withdraw(1) catch e { failed = true }
    expect(failed)
    expect(a.balance == 0)
}
