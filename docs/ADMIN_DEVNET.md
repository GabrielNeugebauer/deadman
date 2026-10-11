# Configuração do admin na devnet

Comandos que o admin roda depois de fazer o deploy do programa atualizado na devnet (`ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`). Eles aplicam o modelo de taxas:

- **Taxa de liberação de 2%** em todos os rails (Solana, Cloak e Zcash), cobrada só quando um tier executa ou uma parcela de vesting é liberada. Saque, fechamento, cancelamento e revogação não pagam taxa.
- **Pagamentos em SKR pagam 1,5%** (em qualquer rail), cobrados no próprio SKR. **10% dessa taxa é queimado**; os outros 90% vão para a tesouraria.
- **Reserva de SKR:** o dono pode deixar SKR no plano para pagar a taxa dos outros ativos. Cada liberação cobra então 1,5% do valor em dólar (preços Pyth) em SKR da reserva, com a mesma queima de 10%, e o herdeiro recebe 100%. Se a reserva não cobre ou um preço está velho, cai nos 2% no próprio ativo. Precisa dos feeds de preço da seção 2.
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

## 2. Feeds de preço (taxa paga com a reserva de SKR)

O programa só lê preços que o admin registrou (`set_price_feed`, uma conta `PriceFeed` por mint) e só da conta canônica do push oracle da Pyth (shard 0) de cada feed. Quem executa a liberação não escolhe o preço. Registre os quatro ativos da devnet:

```sh
dart run tool/set_price_feed.dart --keypair <admin.json> --asset sol
dart run tool/set_price_feed.dart --keypair <admin.json> --asset usdc
dart run tool/set_price_feed.dart --keypair <admin.json> --asset skr
dart run tool/set_price_feed.dart --keypair <admin.json> --asset ore
```

| `--asset` | Mint na devnet                                                    | Feed Pyth (id)                                                       | Conta shard 0                                  | Quem mantém o preço   |
| --------- | ----------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------- | --------------------- |
| `sol`     | `So11111111111111111111111111111111111111112` (SOL nativo)         | SOL/USD `ef0d8b6f…80b56d`                                            | `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE` | Pyth (patrocinado)    |
| `usdc`    | `Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk` (USDC de teste)      | USDC/USD `eaa020c6…e9c94a`                                           | `Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX` | Pyth (patrocinado)    |
| `skr`     | `4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc` (SKR de teste)       | SKR/USD `38846ec4…a93bf9`                                            | `AFrJWhfWt3vDtGPdcwTyLyHz8ZQ4M9L2z1YHThY5Vbj5` | nosso pusher (seção 3) |
| `ore`     | `6KdRjrWYouFLmEcNeDpJkc9AUgzvmE7cn3DbAx2KfSyt` (`AppConfig.oreMint`) | ORE/USD `142b804c…cad504`                                            | `GYYQ8gbX4Tndc4WMJ9jSjZTePTvbmgRRxByt54ZQYqvZ` | nosso pusher (seção 3) |

- Os mints de teste da devnet usam o preço real do feed. Cada comando é idempotente: rodar de novo atualiza o registro. A ferramenta usa a devnet por padrão, recusa a mainnet sem `--mainnet`, confere que o keypair é o admin da Config e mostra o registro antes e depois.
- `--max-age` padrão é 600 s (máximo 3600). Medido em 2026-10-09: a Pyth atualiza as contas patrocinadas de SOL/USD e USDC/USD na devnet a cada ~5 min (chegam a ~320 s de idade), então 300 s deixaria o preço velho boa parte do tempo. `--max-age 0` desliga o feed (o ativo volta a pagar 2% nele mesmo).
- Outro ativo: `--mint <mint> --feed-id <id hex>` (ids em `https://hermes.pyth.network/v2/price_feeds?query=<símbolo>&asset_type=crypto`). Se o feed não for patrocinado, inclua-o em `kora/pyth-price-config.yaml`. Na mainnet também existe `--asset jitosol`.
- Conferir (não envia nada): `dart run tool/set_price_feed.dart show`. Para cada ativo, mostra o registro e o estado da conta de preço (preço, idade, confiança, e se o programa o usaria); sem registro, mostra a conta shard 0 que seria registrada.

**Conta de SKR da tesouraria.** Sem ela o programa não tem onde pôr os 90% e cai nos 2% no ativo. Abra uma vez (o primeiro pagamento de um tier em SKR também a abre):

```sh
spl-token create-account 4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc \
  --owner <tesouraria> --fee-payer <admin.json> --url devnet
```

`<tesouraria>` é o `treasury` da Config (`dart run tool/e2e_skr_fee_reserve.dart --dry-run` mostra; hoje `A9SftPMejLGAiYFJ3Zk4J74Trtvq3SC5k3Un7YnSnvtH`).

## 3. Pusher de preços Pyth (SKR/USD e ORE/USD)

A Pyth não patrocina SKR/USD nem ORE/USD na Solana: a conta shard 0 do SKR (`AFrJWhf…`) ainda não existe e a do ORE está parada desde fevereiro. Sem pusher, toda liberação com reserva cai nos 2% no ativo. O pusher é o pacote oficial `@pythnetwork/price-pusher` em modo solana, que lê o Hermes e publica na devnet as atualizações dos feeds em `kora/pyth-price-config.yaml` (a cada 120 s, ou antes se o preço mudar 0,5%).

1. Instalar (uma vez, ~700 MB em `tool/pyth_pusher/node_modules`, Node 24 ou mais novo):

   ```sh
   (cd tool/pyth_pusher && npm ci)
   ```

2. Criar e financiar a chave que paga as atualizações. Ela só paga taxas de rede e o aluguel das contas de preço; não tem outro papel:

   ```sh
   solana-keygen new --no-bip39-passphrase -o kora/pyth-pusher-key.json
   solana transfer $(solana-keygen pubkey kora/pyth-pusher-key.json) 1 \
     --allow-unfunded-recipient --url devnet
   ```

   Custo estimado: algumas transações por atualização (as duas cotações vão juntas), na ordem de 0,03 a 0,05 SOL por dia, mais ~0,0018 SOL de aluguel na primeira vez que a conta do SKR é criada. Confira o saldo com `solana balance $(solana-keygen pubkey kora/pyth-pusher-key.json) --url devnet`.

3. Chave do Hermes: em 2026-10-09 o `https://hermes.pyth.network` público responde 401 em `/v2/updates`, que o pusher usa. Coloque em `kora/.env` (o script lê só estas variáveis de lá, nunca a chave do Kora):

   ```sh
   PYTH_HERMES_ACCESS_TOKEN=<chave da Pyth>
   # opcional: PYTH_HERMES_URL=<outro Hermes>, PYTH_PUSHER_CU_PRICE=<micro-lamports por CU, padrão 0 na devnet>
   ```

4. Iniciar e parar:

   ```sh
   scripts/pyth_pusher_start.sh   # ou scripts/kora_start.sh, que o inicia quando kora/pyth-pusher-key.json existe
   scripts/pyth_pusher_stop.sh    # scripts/kora_stop.sh também o para
   tail -f kora/logs/pyth-pusher.log
   ```

   O script confere que o `RPC_URL` é da devnet (hash do genesis), não passa a chave do Hermes na linha de comando (vai para `kora/pyth-pusher.run.json`, modo 600, ignorado pelo git) e desliga o servidor de métricas. Depois de um ou dois minutos, `dart run tool/set_price_feed.dart show` deve mostrar SKR e ORE como `usable`.

## 4. Conferir

```sh
dart run tool/e2e_skr_nft.dart --dry-run
dart run tool/e2e_skr_fee_reserve.dart --dry-run
```

Não envia nada. Imprime as taxas lidas da Config e o que o teste ao vivo checaria: num tier de 10 SKR, taxa de 0,15 SKR (1,5%), 0,015 SKR queimado (o supply cai exatamente isso), 0,135 SKR para a tesouraria e 9,85 SKR para o herdeiro. Se a Config não tiver esse SKR configurado, diz que o teste seria pulado e por quê. O teste ao vivo é o mesmo comando sem `--dry-run` (precisa dos CLIs `solana` e `spl-token`, com a carteira padrão sendo a autoridade de mint do SKR de teste).

O segundo confere a reserva de SKR. O dry run lê a Config, o registro de preços e os preços, e imprime a cotação: num tier de 0,05 SOL, a taxa em SKR (1,5% do valor), quanto é queimado e quanto vai para a tesouraria. Se faltar um feed ou um preço estiver velho, diz que a parte do SKR seria pulada e por quê. O teste ao vivo (sem `--dry-run`, mesmos CLIs) cria com chaves descartáveis:

- um plano com um tier de 0,05 SOL e uma reserva de 3× a cotação. Depois da liberação confere: herdeiro +100% do tier; evento `SkrFeePaid`; a reserva e o SKR do cofre caem exatamente a taxa do evento, que fica a até 2% da cotação feita antes; o supply cai os 10% queimados; a tesouraria ganha os 90%. Fechar o plano devolve o resto da reserva ao dono;
- um plano com reserva de 1 unidade, que não cobre a taxa: a liberação paga 2% em SOL (herdeiro +98%), a reserva fica igual e nada é queimado. Depois o dono saca a reserva e ela fica vazia.

Se a conta de SKR da tesouraria não existir, o teste a abre (o dono descartável paga o aluguel).

## 5. Trocar o admin (dois passos)

O admin atual propõe, e a nova chave aceita. Nada muda até o aceite.

```sh
dart run tool/set_config.dart propose-admin --keypair <admin.json> --new-admin <nova chave>
dart run tool/set_config.dart accept-admin --keypair <nova-chave.json>
```

Para cancelar uma proposta pendente: `propose-admin --keypair <admin.json> --new-admin none`. Só proponha depois da migração do passo 1.

## 6. Gateway e keeper

Depois do deploy, reinicie o gateway e os nós Kora (`scripts/kora_stop.sh` e `scripts/kora_start.sh`) e o keeper, para que usem as contas novas das instruções.

- **Reserva de SKR no gateway:** o paymaster aceita `fund_skr_reserve` (tier account se o Kora abrir a conta de SKR do cofre, plan se for junto com a criação do plano, basic depois) e `withdraw_skr_reserve` (basic). As liberações aceitam as 8 contas extras de um plano com reserva, tanto no paymaster quanto no claim de SOL patrocinado. `set_price_feed` é recusado. O `kora/sponsor.toml` agora permite o SPL Token, porque o claim de SOL de um plano com reserva queima e transfere SKR por CPI; por isso o nó sponsor precisa reiniciar.

- **Gateway:** os lockdowns têm agora um orçamento próprio, separado dos pulses e dos claims (auditoria M-3): até 3 por plano e 24 por chave guardiã a cada 24 h, num total de 1000, e só para um plano com pagamento pendente que tenha pelo menos 0,01 SOL acima do aluguel ou saldo de um token das suas regras. Ajuste com `GATEWAY_LOCKDOWNS_PER_VAULT`, `GATEWAY_LOCKDOWNS_PER_SIGNER`, `GATEWAY_LOCKDOWNS_GLOBAL` e `GATEWAY_LOCKDOWN_MIN_LAMPORTS`. O paymaster só paga o aluguel de um plano novo num endereço vazio.
- **Keeper:** só libera um tier ou uma parcela quando a parte da taxa que fica com a tesouraria cobre a taxa de rede e o aluguel de ATA que ele paga (auditoria M-4); o resto fica para o beneficiário reivindicar. Sem `--price`, só o USDC tem preço conhecido. Num plano com reserva de SKR, o keeper passa as contas do oráculo, prevê se o programa vai cobrar em SKR e, nesse caso, conta os 90% de SKR da tesouraria: pelo `--price` do SKR se houver, senão como 1,35% do valor do pagamento (o preço do ativo pago). Para o keeper liberar pagamentos em SKR, passe o preço em lamports por unidade base:

```sh
dart run tool/keeper.dart --keypair <keeper.json> --every 60 \
  --price 4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc=<lamports por unidade base>
```

## Mainnet

Os mesmos comandos funcionam na mainnet com `--rpc <url da mainnet> --mainnet`. Com `--mainnet`, o `--skr-mint` padrão já é o SKR da mainnet (`SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3`), e o `--asset` do `set_price_feed.dart` usa os mints reais (SOL, USDC, SKR, ORE e JitoSOL). O SKR/USD também não é patrocinado na mainnet: rode o pusher com `CLUSTER=mainnet-beta CONFIRM_MAINNET=yes scripts/pyth_pusher_start.sh`, com a chave em `kora/mainnet/pyth-pusher-key.json` e `RPC_URL` e `PYTH_HERMES_ACCESS_TOKEN` em `kora/.env.mainnet` (taxa de prioridade padrão 50 000 micro-lamports por CU). Uma Config nova (`tool/init_config.dart`) já nasce com 2% / 2% / 1,5% / 10%. Só rode na mainnet com confirmação explícita, depois do deploy de lá.

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
