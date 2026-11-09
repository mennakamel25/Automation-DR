import pytest
from fastapi.testclient import TestClient

from app import main


class FakeDB:
    def __init__(self):
        self.items = []
        self.generation = 1
        self.standby = False
        self.down = False

    def __call__(self, sql, params=(), fetch="none"):
        if self.down:
            raise RuntimeError("connection refused")
        s = " ".join(sql.split())
        if "pg_is_in_recovery() AS standby" in s and "inet_server_addr" not in s:
            return {"standby": self.standby}
        if "inet_server_addr" in s:
            return {"db_host": "10.10.3.10", "standby": self.standby}
        if "FROM dr_meta" in s:
            return {"value": str(self.generation)}
        if s.startswith("SELECT id, title"):
            return list(reversed(self.items))
        if s.startswith("INSERT INTO items"):
            row = {"id": len(self.items) + 1, "title": params[0], "done": False, "created_at": "now"}
            self.items.append(row)
            return row
        if s.startswith("DELETE FROM items"):
            self.items = [i for i in self.items if i["id"] != params[0]]
            return None
        if s.startswith("UPDATE items"):
            for i in self.items:
                if i["id"] == params[2]:
                    if params[0] is not None:
                        i["done"] = params[0]
                    return i
            return None
        return None


@pytest.fixture()
def env(monkeypatch, tmp_path):
    db = FakeDB()
    gen = tmp_path / "generation"
    gen.write_text("1")
    monkeypatch.setattr(main, "run", db)
    monkeypatch.setattr(main, "GENERATION_FILE", gen)
    return db, gen, TestClient(main.app)


def test_healthz_does_not_need_database(env):
    db, _, client = env
    db.down = True
    assert client.get("/healthz").json()["status"] == "ok"


def test_readyz_ok_and_standby_rejected(env):
    db, _, client = env
    assert client.get("/readyz").status_code == 200
    db.standby = True
    assert client.get("/readyz").status_code == 503


def test_crud_roundtrip(env):
    _, _, client = env
    r = client.post("/api/items", json={"title": "hello"})
    assert r.status_code == 201
    assert client.get("/api/items").json()[0]["title"] == "hello"
    assert client.patch("/api/items/1", json={"done": True}).json()["done"] is True
    assert client.delete("/api/items/1").status_code == 204


def test_stale_generation_refuses_writes(env):
    db, gen, client = env
    db.generation = 2  # a DR failover happened, this node still holds generation 1
    assert client.post("/api/items", json={"title": "x"}).status_code == 503
    assert client.get("/api/items").status_code == 200  # reads still fine
    gen.write_text("2")
    assert client.post("/api/items", json={"title": "x"}).status_code == 201


def test_database_down_is_503_not_500(env):
    db, _, client = env
    db.down = True
    assert client.get("/api/items").status_code == 503
    assert client.post("/api/items", json={"title": "x"}).status_code == 503
    info = client.get("/api/info").json()
    assert info["db_ok"] is False and info["writes_allowed"] is False


def test_validation(env):
    _, _, client = env
    assert client.post("/api/items", json={"title": ""}).status_code == 422


def test_info_reports_site_and_region(env, monkeypatch):
    _, _, client = env
    monkeypatch.setattr(main, "SITE", "dr")
    monkeypatch.setattr(main, "REGION", "eu-central-1")
    info = client.get("/api/info").json()
    assert info["site"] == "dr" and info["region"] == "eu-central-1"
    assert info["db_ok"] is True and info["writes_allowed"] is True
