fn with_tax(net: float) -> float {
    return net * 1.2
}

check "tax is added" {
    expect(with_tax(10.0) == 12.0)
}
