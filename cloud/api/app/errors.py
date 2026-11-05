"""API のエラー。{"error": "<コード>"} で返す（コードの一覧は schema/README.md）。"""


class ApiError(Exception):
    def __init__(self, status: int, code: str):
        super().__init__(code)
        self.status, self.code = status, code
