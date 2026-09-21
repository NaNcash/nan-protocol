test:
	forge test -vv

model:
	python3 model/simulate.py
	python3 model/check_invariants.py

check:
	forge fmt --check
	forge test -vv
	forge build --sizes
	forge lint
	python3 model/check_invariants.py

deploy-dry-run:
	forge script script/Deploy.s.sol:Deploy --rpc-url "$$RPC_URL"
