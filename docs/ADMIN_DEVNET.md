# Configuração do admin na devnet

Comandos que o admin roda depois de fazer o deploy do programa atualizado na devnet (`ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`). Eles aplicam o modelo de taxas:

- **Taxa de liberação de 2%** em todos os rails (Solana, Cloak e Zcash), cobrada só quando um tier executa ou uma parcela de vesting é liberada. Saque, fechamento, cancelamento e revogação não pagam taxa.
- **Pagamentos em SKR pagam 1,5%** (em qualquer rail), cobrados no próprio SKR. **10% dessa taxa é queimado**; os outros 90% vão para a tesouraria.
- Não existe mais assinatura (Plus): nenhuma conta de assinatura, nenhuma isenção de taxa.

`<admin.json>` é o keypair do admin da Config (a upgrade authority do programa). As ferramentas usam a devnet como RPC padrão e recusam a mainnet sem `--mainnet`. Cada uma imprime a Config antes e depois da transação, e a assinatura.

## 1. Taxas novas (e migração da Config)

```sh
dart run tool/set_config.dart --keypair <admin.json> \
  --fee-public 200 --fee-private 200 --fee-skr 150 --skr-burn-bps 1000 \
  --skr-mint 4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc
```

- Os valores são em bps: 200 = 2%, 150 = 1,5%, e `--skr-burn-bps 1000` = 10% da taxa em SKR. O teto do programa é 500 bps por taxa e 10000 para a queima. Esses números já são os padrões da ferramenta; o comando acima só os deixa explícitos.
- O mint acima é o SKR de teste da devnet (`AppConfig.skrMint`). `--skr-mint none` desliga a taxa de SKR (o SKR passa a pagar os 2% normais, sem queima).
- A tesouraria continua a mesma; para trocar, use `--treasury <addr>`. Ela precisa ser uma carteira comum (conta do System Program): o programa recusa sysvars, programas e contas de outros programas.
- **Migração obrigatória:** a Config atual da devnet ainda está no layout antigo (77 bytes). Até esse comando rodar uma vez, toda liberação, `propose_admin` e `accept_admin` falham. A ferramenta avisa quando a Config está no layout antigo; o `set_config` realoca a conta para 209 bytes e o admin paga o aluguel extra (cerca de 0,00092 SOL).
- Não precisa abrir a conta de SKR da tesouraria: quem executa a liberação cria a ATA da tesouraria quando há taxa para ela.

## 2. Conferir

```sh
dart run tool/e2e_skr_nft.dart --dry-run
```

Não envia nada. Imprime as taxas lidas da Config e o que o teste ao vivo checaria: num tier de 10 SKR, taxa de 0,15 SKR (1,5%), 0,015 SKR queimado (o supply cai exatamente isso), 0,135 SKR para a tesouraria e 9,85 SKR para o herdeiro. Se a Config não tiver esse SKR configurado, diz que o teste seria pulado e por quê. O teste ao vivo é o mesmo comando sem `--dry-run` (precisa dos CLIs `solana` e `spl-token`, com a carteira padrão sendo a autoridade de mint do SKR de teste).

## 3. Trocar o admin (dois passos)

O admin atual propõe, e a nova chave aceita. Nada muda até o aceite.

```sh
dart run tool/set_config.dart propose-admin --keypair <admin.json> --new-admin <nova chave>
dart run tool/set_config.dart accept-admin --keypair <nova-chave.json>
```

Para cancelar uma proposta pendente: `propose-admin --keypair <admin.json> --new-admin none`. Só proponha depois da migração do passo 1.

## 4. Gateway e keeper

Depois do deploy, reinicie o gateway (`scripts/kora_stop.sh` e `scripts/kora_start.sh`) e o keeper, para que usem as contas novas das instruções.

- **Gateway:** os lockdowns têm agora um orçamento próprio, separado dos pulses e dos claims (auditoria M-3): até 3 por plano e 24 por chave guardiã a cada 24 h, num total de 1000, e só para um plano com pagamento pendente que tenha pelo menos 0,01 SOL acima do aluguel ou saldo de um token das suas regras. Ajuste com `GATEWAY_LOCKDOWNS_PER_VAULT`, `GATEWAY_LOCKDOWNS_PER_SIGNER`, `GATEWAY_LOCKDOWNS_GLOBAL` e `GATEWAY_LOCKDOWN_MIN_LAMPORTS`. O paymaster só paga o aluguel de um plano novo num endereço vazio.
- **Keeper:** só libera um tier ou uma parcela quando a parte da taxa que fica com a tesouraria cobre a taxa de rede e o aluguel de ATA que ele paga (auditoria M-4); o resto fica para o beneficiário reivindicar. Sem `--price`, só o USDC tem preço conhecido. Para o keeper liberar pagamentos em SKR, passe o preço em lamports por unidade base:

```sh
dart run tool/keeper.dart --keypair <keeper.json> --every 60 \
  --price 4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc=<lamports por unidade base>
```

## Mainnet

Os mesmos comandos funcionam na mainnet com `--rpc <url da mainnet> --mainnet`. Com `--mainnet`, o `--skr-mint` padrão já é o SKR da mainnet (`SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3`). Uma Config nova (`tool/init_config.dart`) já nasce com 2% / 2% / 1,5% / 10%. Só rode na mainnet com confirmação explícita, depois do deploy de lá.

## NFTs de skin do Boney (devnet)

Cunhados em 2026-10-07 com `tool/create_test_nft.dart` (NFT clássico com master edition, símbolo `BONEY`, autoridade de update = keypair de scratch) e enviados para `AppAYe7kXr8uqApxshXvV9CNEka3AZtBwNgX4NBK9PbA`:

| Skin    | Nome            | Mint                                           |
| ------- | --------------- | ---------------------------------------------- |
| Coroa   | `Boney Crown`   | `67KeDdLUXpVRXHMYGFU5TLEeM3vMDVqH6B7c3XEvFFFK` |
| Boné    | `Boney Cap`     | `8Yiw22zP1baAocnVM7PtQ29MYQfEiGUVWBSye7tjxchC` |
| Óculos  | `Boney Glasses` | `4Pa3ev4xdvyhCub7GCLFHrAdAxjx8U5fn5qRF2zpVbHN` |

O URI de cada um aponta para `docs/brand/nft/boney-{crown,cap,glasses}.json` na branch `main` do GitHub; a imagem aparece nas carteiras depois que esses arquivos chegarem à `main`. O app não depende da imagem: a skin é liberada pelo símbolo e pelo nome. Para cunhar outro:

```bash
dart run tool/create_test_nft.dart --keypair <scratch.json> --to <carteira> \
  --name "Boney Crown" --symbol BONEY \
  --uri https://raw.githubusercontent.com/GabrielNeugebauer/deadman/main/docs/brand/nft/boney-crown.json
```
