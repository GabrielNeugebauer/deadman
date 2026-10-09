"""Simulação de receita do Deadman, 36 meses (out/2026 a set/2029). Todas as premissas são estimativas."""

SCEN = {
    "Conservador": dict(users=(300, 1_500, 4_000), vault=500, user_churn=0.04,
                        rel=0.03, wd=0.25, skr=0.50, k=5,
                        cur=dict(conv=0.005, churn=0.18),
                        rec=dict(conv=0.02, renew=0.30)),
    "Base": dict(users=(1_000, 6_000, 20_000), vault=1_500, user_churn=0.03,
                 rel=0.05, wd=0.30, skr=0.40, k=5,
                 cur=dict(conv=0.015, churn=0.14),
                 rec=dict(conv=0.05, renew=0.45)),
    "Otimista": dict(users=(3_000, 20_000, 60_000), vault=3_000, user_churn=0.02,
                     rel=0.08, wd=0.30, skr=0.30, k=5,
                     cur=dict(conv=0.03, churn=0.10),
                     rec=dict(conv=0.08, renew=0.60)),
}
FEE = 0.005


def path(users):
    start, out = 10, []
    prev = start
    for y, end in enumerate(users):
        for m in range(12):
            out.append(prev + (end - prev) * (m + 1) / 12)
        prev = end
    return out


def run(s, model):
    u = path(s["users"])
    paid, prev_u = 0.0, 10
    yr = [dict(sub=0, fee_rel=0, fee_wd=0, burn=0, paid_end=0, aum_end=0) for _ in range(3)]
    renew_queue = [0.0] * 48  # annual plan cohorts
    for t in range(36):
        y = t // 12
        users = u[t]
        gross_new = max(0, users - prev_u) + prev_u * s["user_churn"]
        prev_u = users
        aum = users * s["vault"]
        if model == "cur":
            p = s["cur"]
            paid = paid * (1 - p["churn"]) + gross_new * p["conv"]
            skr = s["skr"]
            yr[y]["sub"] += paid * ((1 - skr) * 40 + skr * 35 * 0.70)
            yr[y]["burn"] += paid * skr * 35 * 0.30
        else:
            p = s["rec"]
            new_paid = gross_new * p["conv"]
            renewing = renew_queue[t] * p["renew"]
            cohort = new_paid + renewing
            renew_queue[t + 12] += cohort
            paid = sum(renew_queue[t + 1:t + 13])
            skr = s["skr"]
            # Plano anual US$79; em SKR US$69, sem burn
            yr[y]["sub"] += cohort * ((1 - skr) * 79 + skr * 69)
        paid_aum = min(aum, paid * s["k"] * s["vault"])
        free_aum = aum - paid_aum
        yr[y]["fee_rel"] += free_aum * s["rel"] / 12 * FEE
        if model == "cur":
            yr[y]["fee_wd"] += free_aum * s["wd"] / 12 * FEE
        yr[y]["paid_end"] = paid
        yr[y]["aum_end"] = aum
    return yr


for name, s in SCEN.items():
    for model in ("cur", "rec"):
        r = run(s, model)
        print(f"\n{name} / {'ATUAL (0,5% exec+cancel, US$40/mês, 30% burn)' if model=='cur' else 'RECOMENDADO (0,5% só na liberação, US$79/ano)'}")
        tot = 0
        for i, x in enumerate(r):
            t = x["sub"] + x["fee_rel"] + x["fee_wd"]
            tot += t
            print(f"  Ano {i+1}: usuários fim {s['users'][i]:>6} | AUM fim US${x['aum_end']:>12,.0f} | pagantes fim {x['paid_end']:>7,.0f} | "
                  f"assin US${x['sub']:>9,.0f} | taxa lib US${x['fee_rel']:>8,.0f} | taxa cancel US${x['fee_wd']:>8,.0f} | "
                  f"burn US${x['burn']:>7,.0f} | TOTAL US${t:>10,.0f}")
        print(f"  3 anos: US${tot:,.0f}")

# Break-even assinatura x taxa
for price in (480, 420, 79, 69):
    print(f"Break-even US${price}/ano = US${price/FEE:,.0f} movimentados/ano")
# Custo Kora por check-in
sol = 115.65
lam = 10_000
print("Custo por check-in (2 assinaturas, sem priority fee): US$", lam / 1e9 * sol, " /ano semanal:", lam / 1e9 * sol * 52)
